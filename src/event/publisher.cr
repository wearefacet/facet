# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "../event"
require "../doctype/definition_store"

module Facet
  module Event
    # Fiber-local event enqueue that flushes after the DB transaction commits.
    #
    # Services call `Event::Publisher.enqueue(...)` during mutation processing.
    # The HTTP layer calls `Event::Publisher.flush` after the DB transaction
    # commits (but before the HTTP response is written). If the transaction
    # fails, the fiber-local queue is discarded automatically.
    #
    # ## Manager requirement
    #
    # A manager **must** be set at startup (via `Publisher.manager=`). Without it
    # `enqueue` buffers events but `flush` raises a hard error.
    #
    # In production the manager is an `Event::Manager` backed by Redis.
    # In tests or single-process setups, use `Event::InProcessManager` to
    # keep events in memory without a Redis connection.
    module Publisher
      # The event manager instance. Must respond to `publish_resource_event`.
      # Set to an `Event::Manager` instance in production (from main.cr) or
      # an `Event::InProcessManager` in tests / single-process dev.
      class_getter manager : Manager | InProcessManager? = nil

      # A single pending event.
      #
      # `cause` carries the mutation's audit cause (`Mutation::Cause` —
      # kind/name/event/source/parent/trace). It mirrors the
      # `mutations.meta.cause` JSON so event consumers (hooks, replication,
      # webhooks) can link their own writes to the source mutation and
      # inherit its causal trace without parsing string conventions.
      #
      # `reentrant` marks events emitted by a replication-driven mutation.
      # Downstream replication handlers inspect the `reentrant` header and
      # skip — this is the one-hop guarantee that prevents A→B→C chains from
      # propagating transitively.
      # `payload` overrides the default `{"id": doc_id}` content. Events
      # that carry more than a document id (e.g. the `notified` event) use
      # it. `fanout_channels` overrides the derived document fanout channel
      # (`fanout:{domain}.{doc_type}:{doc_id}`); `nil` keeps the default,
      # an explicit list replaces it — the `notified` event uses this to
      # publish only to the recipient's own channel.
      #
      # `cause` carries a pre-serialized cause object (the common path).
      # `cause_struct` carries the cause as a `Mutation::Cause` value that
      # serializes only at flush time. Bulk writers (the import loop) use
      # `cause_struct` so a large buffered batch does not hold one parsed
      # `JSON::Any` tree per row until the single post-commit flush — the
      # struct is a handful of small string refs, serialized once per event
      # in `publish_pending`. At most one of the two is set.
      record PendingEvent,
        domain : String,
        doc_type : String,
        doc_id : String,
        event : String,
        mutation_id : String? = nil,
        actioner_id : String = "system",
        cause : ::JSON::Any? = nil,
        reentrant : Bool = false,
        payload : Hash(String, ::JSON::Any)? = nil,
        fanout_channels : Array(String)? = nil,
        cause_struct : Mutation::Cause? = nil

      # ── Configuration ────────────────────────────────────────────────────────

      # Set the manager reference at startup (from main.cr or spec_helper).
      def self.manager=(mgr : Manager | InProcessManager?) : Nil
        @@manager = mgr
      end

      # Installs a config-built manager when the process has none. CLI
      # commands have no boot-time manager (only `run_server` sets one), but
      # their mutations buffer events that must publish — `CLI.dispatch`
      # calls this before flushing. An existing manager survives: the spec
      # suite's `InProcessManager` is never replaced. Construction does not
      # connect — the Redis client opens on first publish — so a command
      # that buffers nothing never touches Redis.
      def self.ensure_config_manager : Nil
        @@manager ||= Manager.new(
          config: Facet::Config.instance.event,
          service_id: Facet::Service.service_id("facet-cli"),
        )
      end

      # ── Enqueue ────────────────────────────────────────────────────────────

      # Enqueue a resource event for publication after the current DB
      # transaction commits. Uses fiber-local storage so concurrent requests
      # on different fibers do not interfere.
      def self.enqueue(
        domain : String,
        doc_type : String,
        doc_id : String,
        event : String,
        mutation_id : String? = nil,
        actioner_id : String = "system",
        cause : ::JSON::Any? = nil,
        reentrant : Bool = false,
        payload : Hash(String, ::JSON::Any)? = nil,
        fanout_channels : Array(String)? = nil,
        cause_struct : Mutation::Cause? = nil,
      ) : Nil
        queue = Fiber.current.event_publish_queue ||= [] of PendingEvent
        queue << PendingEvent.new(
          domain: domain,
          doc_type: doc_type,
          doc_id: doc_id,
          event: event,
          mutation_id: mutation_id,
          actioner_id: actioner_id,
          cause: cause,
          reentrant: reentrant,
          payload: payload,
          fanout_channels: fanout_channels,
          cause_struct: cause_struct,
        )
      end

      # ── Flush ──────────────────────────────────────────────────────────────

      # Publish all pending events for the current fiber to the manager, then
      # clear the queue.
      #
      # Raises if `manager` is nil. For tests, set
      # `Publisher.manager = InProcessManager.new`.
      #
      # A failed flush is counted on `Event::Loss` (once per failure, plus
      # the queue size at failure) — losses are counted, not silent.
      def self.flush : Nil
        mgr = @@manager
        queue = Fiber.current.event_publish_queue
        raise "Event::Publisher.manager is not set. " \
              "Call Event::Publisher.manager= at startup " \
              "(or use InProcessManager in tests)." if mgr.nil?

        begin
          publish_pending(mgr.as(Manager | InProcessManager))
        rescue e : Exception
          Log.error { "Event publish flush failed: #{e.message}" }
          Loss.record_flush_failure(queue.try(&.size) || 0)
        ensure
          Fiber.current.event_publish_queue = nil
        end
      end

      # Fail-loud flush for a process that ends right after the flush —
      # CLI commands. `flush` counts a lost publish on `Event::Loss`, but a
      # CLI process dies immediately, so a counted loss would be invisible:
      # the operator would see a success exit code over a mutation no
      # consumer ever saw. This variant re-raises instead, so the caller
      # can turn the failure into a non-zero exit. The queue is still
      # discarded (a failed publish drops the events — at-most-once).
      def self.flush! : Nil
        mgr = @@manager
        raise "Event::Publisher.manager is not set. " \
              "Call Event::Publisher.manager= at startup " \
              "(or use InProcessManager in tests)." if mgr.nil?

        publish_pending(mgr.as(Manager | InProcessManager))
      ensure
        Fiber.current.event_publish_queue = nil
      end

      # The shared publish loop. Raises on the first publish failure —
      # `flush` turns that into a counted loss, `flush!` surfaces it.
      private def self.publish_pending(mgr : Manager | InProcessManager) : Nil
        queue = Fiber.current.event_publish_queue
        return if queue.nil? || queue.empty?

        queue.each do |pe|
          headers = {
            "actioner_id" => ::JSON::Any.new(pe.actioner_id),
            "domain"      => ::JSON::Any.new(pe.domain),
            "doc_type"    => ::JSON::Any.new(pe.doc_type),
          }
          if mutation_id = pe.mutation_id
            headers["mutation_id"] = ::JSON::Any.new(mutation_id)
          end
          if cause = pe.cause
            headers["cause"] = cause
          elsif cause_struct = pe.cause_struct
            headers["cause"] = cause_struct.to_json_any
          end
          if pe.reentrant
            headers["reentrant"] = ::JSON::Any.new(true)
          end

          mgr.publish_resource_event(
            domain: pe.domain,
            resource_type: "#{pe.domain}:#{pe.doc_type}",
            resource_id: pe.doc_id,
            event: pe.event,
            payload: pe.payload || {"id" => ::JSON::Any.new(pe.doc_id)},
            headers: headers,
            fanout_channels: pe.fanout_channels,
          )
        end
      end

      # Returns the number of pending events for the current fiber (for
      # diagnostics / specs).
      def self.pending_count : Int32
        queue = Fiber.current.event_publish_queue
        queue.nil? ? 0 : queue.size
      end

      # Discards every pending event of the current fiber without
      # publishing. A failed transaction's buffered row mutations must not
      # ride a later flush on the same fiber: an HTTP request fiber simply
      # dies, but a worker fiber is long-lived, so services that roll back
      # inside a job must discard explicitly.
      def self.discard : Nil
        Fiber.current.event_publish_queue = nil
      end

      # ── Aggregate child-change event ─────────────────────────────────

      # Enqueues one `child_changed` frame keyed to the **parent** of an
      # owned child mutation. Call it after the child's own mutation event
      # is enqueued; both ride the same fiber-local queue and flush
      # together after the transaction commits.
      #
      # The frame rides the parent's stream (`FACET:RESOURCE:{domain}:
      # {parent_doctype}`) and the parent's per-document fanout channel —
      # the collection channel is skipped, because the payload is an
      # envelope, not a document-id frame.
      #
      # Skips (silently, no frame) when:
      #
      # - the domain is `core` — the doctype-cache subscriber is
      #   channel-keyed and payload-blind, so a frame on a `core.*`
      #   channel would evict caches spuriously;
      # - the cause kind is `cascade` — the parent's own `deleted` frame
      #   covers the teardown;
      # - the child definition is missing or declares no `member_of` —
      #   without ownership there is no parent doctype to key the frame.
      def self.enqueue_child_changed(
        db : DB::Connection,
        domain : String,
        child_doc_type : String,
        child_doc_id : String,
        parent_doc_id : String,
        action : String,
        mutation_id : String,
        actioner_id : String,
        cause : Mutation::Cause? = nil,
        reentrant : Bool = false,
      ) : Nil
        return if domain == "core"

        resolved_cause = (cause || Mutation::Cause.root(Mutation::CauseKind::Request)).resolve(mutation_id)
        return if resolved_cause.kind == Mutation::CauseKind::Cascade

        defn = Doctype::DefinitionStore.fetch(db, "#{domain}.#{child_doc_type}")
        return unless defn

        parent_doctype = defn.member_of
        return unless parent_doctype

        child = {
          "doc_type" => JSON::Any.new(child_doc_type),
          "doc_id"   => JSON::Any.new(child_doc_id),
        }
        parent = {
          "doc_type" => JSON::Any.new(parent_doctype),
          "doc_id"   => JSON::Any.new(parent_doc_id),
        }
        payload = {
          "id"     => JSON::Any.new(parent_doc_id),
          "action" => JSON::Any.new(action),
          "child"  => JSON::Any.new(child),
          "parent" => JSON::Any.new(parent),
        }

        enqueue(
          domain: domain,
          doc_type: parent_doctype,
          doc_id: parent_doc_id,
          event: CHILD_CHANGED,
          mutation_id: mutation_id,
          actioner_id: actioner_id,
          cause: resolved_cause.to_json_any,
          reentrant: reentrant,
          payload: payload,
          fanout_channels: ["fanout:#{domain}.#{parent_doctype}:#{parent_doc_id}"],
        )
      end
    end
  end
end
