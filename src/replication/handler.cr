# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "json"
require "pg"
require "../event/message"
require "../mutation/client"
require "../document/update"
require "../doctype/definition_store"
require "../document/artifact_refs"
require "../rbac"
require "../database"
require "../artifact/owners"
require "./registry"
require "./binding"
require "./queries"

module Facet
  module Replication
    # Async source-event handler that propagates producer-side changes to
    # consumer replica fields.
    #
    # Registered as the no-filter subscription callback on the replication
    # `Event::Manager` (one consumer group per consuming domain, subscribed
    # to source doctype streams). On each incoming `Message` it:
    #
    # 1. **Reentrancy skip** — if `headers["reentrant"]` is `true`, ACK and
    #    return immediately. This is the one-hop guarantee that prevents
    #    transitive A→B→C chains.
    # 2. **Resolve source** — from `headers["domain"]` + `headers["doc_type"]`
    #    + `content["id"]`.
    # 3. **Registry lookup** — find bindings for the source doctype.
    # 4. **Source-field-changed pre-check** — DB-direct fetch of the source
    #    projection and compare each consumer's current replica value against
    #    the source's current value; skip if unchanged.
    # 5. **Apply** — for each affected consumer, build a `set`/`unset` diff
    #    and call `Document::Update.call(reentrant: true)`.
    # 6. **Deletion policy** — on `deleted` events, apply `on_source_delete`
    #    (`keep` or `unset`) to each referencing consumer.
    #
    # ACK-on-arrival: the underlying `Subscriber::Stream` runs with `no_ack:
    # true`, so no explicit `XACK` is issued. A transient DB error during
    # the consumer write is permanent until the next source mutation
    # (by design — logged, never retried in v1).
    class Handler
      Log = ::Log.for("facet.replication.handler")

      def initialize(@registry : Registry)
      end

      # Entry point — invoked by the `Event::Manager` for each message on a
      # source doctype stream.
      def call(msg : Facet::Event::Message) : Nil
        # 1. Reentrancy gate.
        if reentrant?(msg)
          Log.debug { "Skipping reentrant event on #{source_descriptor(msg)}" }
          return
        end

        # 2. Resolve source.
        source_doctype, source_id, event_name = resolve_source(msg)
        return if source_doctype.nil? || source_id.nil?

        # 2.5. Aggregate child frames: keyed to the parent, but they name a
        # child mutation. Replica sync is field-scoped on the parent's own
        # fields, and the parent's own created/updated/deleted frames cover
        # it — a child change never maps to a replica field. ACK (the
        # stream runs no_ack) and return; the case below never sees them.
        if event_name == Facet::Event::CHILD_CHANGED
          Log.debug { "Skipping aggregate child_changed on #{source_descriptor(msg)}" }
          return
        end

        # 3. Registry lookup.
        bindings = @registry.bindings_for(source_doctype)
        return if bindings.empty?

        Log.debug do
          "Replication event #{event_name} for #{source_doctype}##{source_id}: " \
          "#{bindings.size} binding(s)"
        end

        # 4-6. Apply per event type. Replication writes consumer documents,
        # so the handler pins the rw pool explicitly.
        Facet::Database.with_db(:read_write) do |db|
          case event_name
          when "deleted"
            handle_source_deleted(db, bindings, source_doctype, source_id, msg)
          when "created", "snapshot", "migrated", "rolled_back"
            handle_source_full(db, bindings, source_doctype, source_id, msg)
          else
            # updated / action events: pre-check + diff against each consumer.
            handle_source_update(db, bindings, source_doctype, source_id, msg)
          end
        end

        # The service-layer update (`Document::Update.call`) enqueues events
        # fiber-locally; the HTTP layer normally calls `Publisher.flush` after
        # the transaction commits. The handler runs outside the HTTP layer, so
        # we flush here to ensure the reentrant event lands on the stream.
        Facet::Event::Publisher.flush
      rescue ex : Exception
        # Logged, not retried — see class docs. The next source mutation will
        # retrigger and catch up.
        Log.error { "Replication handler error: #{ex.message}\n#{ex.backtrace?.try(&.join('\n'))}" }
        Facet::Event::Loss.record_dropped_message
      end

      # ── Event-type handlers ────────────────────────────────────────

      # Create/snapshot/migrate/rollback: every consumer's replica is re-pulled
      # from the current source projection (full sync, no diffing needed).
      private def handle_source_full(
        db : DB::Connection,
        bindings : Array(Binding),
        source_doctype : String,
        source_id : String,
        msg : Facet::Event::Message,
      ) : Nil
        source_content = fetch_source_content(db, source_doctype, source_id)
        return if source_content.nil?

        bindings.each do |binding|
          apply_full_binding(db, binding, source_content, source_id, msg)
        end
      end

      # Update / action: fetch the source projection and apply the new value
      # only to consumers whose current replica value differs. This is the
      # pre-check that avoids spurious empty diffs and unnecessary event
      # emissions on the consumer side.
      private def handle_source_update(
        db : DB::Connection,
        bindings : Array(Binding),
        source_doctype : String,
        source_id : String,
        msg : Facet::Event::Message,
      ) : Nil
        source_content = fetch_source_content(db, source_doctype, source_id)
        return if source_content.nil?

        bindings.each do |binding|
          new_value = source_content.as_h?.try(&.[binding.source_field]?)
          apply_update_binding(db, binding, new_value, source_id, msg)
        end
      end

      # Deletion: apply `on_source_delete` policy to each referencing consumer.
      # The `via` reference field itself is never touched — the dangling id is
      # a true fact.
      private def handle_source_deleted(
        db : DB::Connection,
        bindings : Array(Binding),
        source_doctype : String,
        source_id : String,
        msg : Facet::Event::Message,
      ) : Nil
        bindings.each do |binding|
          case binding.on_source_delete
          when "keep"
            # Do nothing — the replica value and the `via` id stay (tombstone).
            Log.debug { "Source delete keep: #{binding.consumer_doctype} replica untouched" }
          when "unset"
            apply_unset_binding(db, binding, source_id, msg)
          else
            Log.warn { "Unknown on_source_delete '#{binding.on_source_delete}' on #{binding.consumer_doctype}" }
          end
        end
      end

      # ── Binding application ────────────────────────────────────────

      private def apply_full_binding(
        db : DB::Connection,
        binding : Binding,
        source_content : JSON::Any,
        source_id : String,
        msg : Facet::Event::Message,
      ) : Nil
        new_value = source_content.as_h?.try(&.[binding.source_field]?)
        apply_update_binding(db, binding, new_value, source_id, msg)
      end

      private def apply_update_binding(
        db : DB::Connection,
        binding : Binding,
        new_value : JSON::Any?,
        source_id : String,
        msg : Facet::Event::Message,
      ) : Nil
        consumer_ids = Queries.referencing_docs(db, binding, source_id)
        return if consumer_ids.empty?

        cause = replication_cause(binding, source_id, msg, msg.headers["event"]?.try(&.as_s?) || "")

        consumer_ids.each do |consumer_id|
          apply_to_consumer(db, binding, consumer_id, new_value, cause)
        end
      end

      private def apply_unset_binding(
        db : DB::Connection,
        binding : Binding,
        source_id : String,
        msg : Facet::Event::Message,
      ) : Nil
        consumer_ids = Queries.referencing_docs(db, binding, source_id)
        return if consumer_ids.empty?

        cause = replication_cause(binding, source_id, msg, "delete-unset")

        consumer_ids.each do |consumer_id|
          # JSON merge patch: a null patch value removes the key from the
          # consumer's content (an `unset` diff entry), so the replica
          # surface reads as "no value" after the source row is gone.
          call_update_with_body(db, binding, consumer_id, %({"#{binding.replica_field}": null}), cause)
        end
      end

      # Builds the `replication` cause for one source event. `parent` is
      # the source mutation id and `trace` is inherited from the source
      # cause, so a replica update links to — and groups with — the
      # mutation that changed the source field.
      private def replication_cause(
        binding : Binding,
        source_id : String,
        msg : Facet::Event::Message,
        event_name : String,
      ) : Mutation::Cause
        source_mut_id = msg.headers["mutation_id"]?.try(&.as_s?)
        inherited_trace = msg.headers["cause"]?.try(&.as_h?).try { |c| c["trace"]?.try(&.as_s?) }
        Mutation::Cause.new(
          kind: Mutation::CauseKind::Replication,
          name: "#{binding.source_doctype}.#{binding.replica_field}",
          event: event_name,
          source: "#{binding.source_doctype}:#{source_id}",
          parent: source_mut_id,
          trace: inherited_trace || source_mut_id,
        )
      end

      # Fetches the consumer's current replica value, compares against
      # `new_value`, and persists a partial-patch update only when they
      # differ. The second pre-check is a safety net under the handler-side
      # source-field-changed check; harmless if it ends up being a no-op.
      private def apply_to_consumer(
        db : DB::Connection,
        binding : Binding,
        consumer_id : String,
        new_value : JSON::Any?,
        cause : Mutation::Cause,
      ) : Nil
        current = begin
          Mutation::Client.fetch_content(db, binding.consumer_domain, binding.consumer_doctype, consumer_id)
        rescue DB::NoResultsError | PG::Error
          Log.debug { "Consumer #{consumer_id} not found — skipping" }
          return
        end

        current_value = current.as_h?.try(&.[binding.replica_field]?)
        return if current_value == new_value

        # Build a single-field partial-patch body (not a JsonDiff) —
        # `Document::Update.call` expects the patch to deep-merge, not a
        # diff. This way the service layer runs compute (`compute_when`
        # may reference this replica field) and the resulting mutation
        # shows up in the audit log.
        value_json = new_value ? new_value.to_json : "null"
        body = %({"#{binding.replica_field}": #{value_json}})

        call_update_with_body(db, binding, consumer_id, body, cause, new_value)
      end

      # Calls `Document::Update.call` with the partial-patch body and the
      # `reentrant: true` flag. The service layer re-validates the patch
      # (with `allow_system_writes` since reentrant), runs the Lua hook,
      # recomputes dependent computed fields, persists the mutation, and
      # enqueues the event — Event::Publisher.flush is invoked at the end
      # of the same fiber so the event lands in the InProcessManager under
      # tests and on the resource stream in production.
      private def call_update_with_body(
        db : DB::Connection,
        binding : Binding,
        consumer_id : String,
        body : String,
        cause : Mutation::Cause,
        new_value : JSON::Any? = nil,
      ) : Nil
        auth_ctx = Facet::RBAC::AuthContext.system
        result = Facet::Document::Update.call(
          db,
          binding.consumer_domain,
          binding.consumer_doctype,
          consumer_id,
          body,
          auth_ctx,
          cause: cause,
          provenance: Mutation::Provenance.internal,
          reentrant: true,
        )

        case result
        when Facet::Document::Update::Result
          # A replicated `file` field carries an artifact id. Append an owner
          # row in the consumer domain so the artifact is readable through the
          # consumer document (artifacts are transversal — a new owner row is
          # the whole operation, no bytes are copied). Runs inside the same
          # transaction as the replicated write.
          append_replicated_owners(db, binding, consumer_id, new_value)
          Log.debug { "Replicated write on #{consumer_id} (mutation #{result.mutation_id})" }
        when Facet::ServiceError
          # Empty-diff / no-op suppressions surface as 422 with a message —
          # log and move on, this is expected when source and consumer are
          # already in sync.
          Log.debug { "Replication update skipped for #{consumer_id}: #{result.message}" }
        end
      end

      # Appends an `artifact_owners` row when the replicated value is a
      # `file` field (a bare artifact id). The owner row records provenance
      # against the consumer document, with the `view_tag` snapshot resolved
      # from the consumer doctype's current definition at the replica field.
      #
      # Runs inside the caller's transaction (the replicated write already
      # opened one via `Document::Update`). Idempotent — a duplicate append
      # collapses to a no-op.
      private def append_replicated_owners(
        db : DB::Connection,
        binding : Binding,
        consumer_id : String,
        new_value : JSON::Any?,
      ) : Nil
        artifact_id = new_value.try(&.as_s?)
        return if artifact_id.nil? || artifact_id.empty?

        consumer_defn = Doctype::DefinitionStore.fetch(db, "#{binding.consumer_domain}.#{binding.consumer_doctype}")
        return unless consumer_defn

        # Only `file` fields carry attachments. A replicated string field
        # (e.g. a plain text replica) must never be treated as an artifact
        # id — the `artifact_owners.artifact_id` FK would otherwise abort
        # the consumer's transaction.
        leaf = Document::ArtifactRefs.resolve_field_path(consumer_defn, binding.replica_field)
        return unless leaf && leaf.type.try(&.type_name) == "file"

        view_tag = leaf.tags

        Artifact::Owners.append(
          db,
          artifact_id: artifact_id,
          domain: binding.consumer_domain,
          doc_type: binding.consumer_doctype,
          doc_id: consumer_id,
          field_path: binding.replica_field,
          view_tag: view_tag,
          actioner_id: "system:replication",
        )
      end

      # ── Source-read helpers ────────────────────────────────────────

      private def fetch_source_content(
        db : DB::Connection,
        source_doctype : String,
        source_id : String,
      ) : JSON::Any?
        source_domain, source_doctype_unq = parse_qualified(source_doctype)
        return nil if source_domain.nil? || source_doctype_unq.nil?

        Mutation::Client.fetch_content(
          db,
          source_domain.as(String),
          source_doctype_unq.as(String),
          source_id,
        )
      rescue DB::NoResultsError | PG::Error
        Log.debug { "Source #{source_doctype}##{source_id} not found" }
        nil
      end

      # ── Message helpers ────────────────────────────────────────────

      private def reentrant?(msg : Facet::Event::Message) : Bool
        msg.headers["reentrant"]?.try(&.as_bool?) == true
      end

      private def resolve_source(msg : Facet::Event::Message) : {String?, String?, String?}
        headers = msg.headers
        domain = headers["domain"]?.try(&.as_s?)
        doc_type = headers["doc_type"]?.try(&.as_s?)
        event = headers["event"]?.try(&.as_s?) || "unknown"
        source_id = msg.content["id"]?.try(&.as_s?)

        return {nil, nil, nil} if domain.nil? || doc_type.nil? || source_id.nil?

        source_doctype = "#{domain}.#{doc_type}"
        {source_doctype, source_id, event}
      end

      private def source_descriptor(msg : Facet::Event::Message) : String
        domain = msg.headers["domain"]?.try(&.as_s?) || "?"
        doc_type = msg.headers["doc_type"]?.try(&.as_s?) || "?"
        event = msg.headers["event"]?.try(&.as_s?) || "?"
        id = msg.content["id"]?.try(&.as_s?) || "?"
        "#{domain}.#{doc_type}##{id} (#{event})"
      end

      private def parse_qualified(qualified : String) : {String?, String?}
        parts = qualified.split('.', 2)
        if parts.size == 2
          {parts[0], parts[1]}
        else
          {nil, nil}
        end
      end
    end
  end
end
