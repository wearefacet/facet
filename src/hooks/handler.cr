# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "json"
require "../event/message"
require "../database"
require "../event/publisher"
require "../rbac"
require "../grants"
require "./registry"
require "./executor"

module Facet
  module Hooks
    # Async source-event handler that runs `event` hooks for a source
    # mutation.
    #
    # Registered as the no-filter subscription callback on the hooks
    # `Event::Manager` (one consumer group per owning domain, subscribed
    # to source doctype streams). On each incoming `Message` it:
    #
    # 1. **Reentrancy skip** — if `headers["reentrant"]` is `true`, ACK and
    #    return immediately. This is the one-hop guarantee that prevents
    #    hook → event → hook cycles (plan, Reentrancy and ordering).
    # 2. **Resolve source** — from `headers["domain"]` + `headers["doc_type"]`
    #    + `content["id"]`.
    # 3. **Registry lookup** — find `event` hooks whose source selector
    #    matches the source doctype (`hooks_for` returns the union of
    #    specific and domain-wide entries).
    # 4. **Event filter** — if a hook declares `source_events`, skip it
    #    unless the event name is in the list.
    # 5. **Run** — for each matching hook, open a `Hooks::Executor` under
    #    a DB connection and call `_MODULE.on_event(ctx)`.
    # 6. **Flush** — `Event::Publisher.flush` so reentrant write events
    #    land on the stream immediately (mirrors `Replication::Handler`).
    #
    # ACK-on-arrival (the underlying `Subscriber::Stream` runs with
    # `no_ack: true`) — a transient DB error during a hook write is
    # permanent until the next source mutation (logged, not retried),
    # same stance as `Replication::Handler`.
    class Handler
      Log = ::Log.for("facet.hooks.handler")

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

        # 3. Registry lookup.
        hooks = @registry.hooks_for(source_doctype)
        return if hooks.empty?

        # 4. Event filter per hook — keep only those whose `source_events`
        # is nil (match all) or contains this event name.
        matching = hooks.select do |hook|
          events = hook.source_events
          events.nil? || events.includes?(event_name.as(String))
        end
        return if matching.empty?

        Log.debug do
          "Hooks event #{event_name} for #{source_doctype}##{source_id}: " \
          "#{matching.size} hook(s)"
        end

        # 5. Run each hook in declaration order. Hooks write (they run the
        # doctype scripts, which may mutate documents), so the handler pins
        # the rw pool explicitly.
        Facet::Database.with_db(:read_write) do |db|
          matching.each do |hook|
            run_one(db, hook, msg, source_doctype.as(String), source_id.as(String), event_name.as(String))
          end
        end

        # 6. Flush so reentrant events land on the stream immediately —
        # the handler runs outside the HTTP layer's normal post-commit
        # flush path.
        Facet::Event::Publisher.flush
      rescue ex : Exception
        # Logged, not retried — see class docs. The next source mutation
        # will retrigger and catch up.
        Log.error { "Hooks handler error: #{ex.message}\n#{ex.backtrace?.try(&.join('\n'))}" }
        Facet::Event::Loss.record_dropped_message
      end

      # ── Per-hook execution ──────────────────────────────────────────

      private def run_one(
        db : DB::Connection,
        hook : Definition::Hook,
        msg : Facet::Event::Message,
        source_doctype : String,
        source_id : String,
        event_name : String,
      ) : Nil
        owning_domain = hook.owning_domain
        return if owning_domain.nil?

        # Grant gate (G3). A hook whose source domain is foreign fires only
        # when an active grant admits the owning domain on the source
        # doctype; same-domain events keep full delivery (D7). The gate
        # admits on any granted tag — `ctx.event.content` below projects
        # the payload down to the actually-covered fields.
        source_domain, source_doctype_unq = parse_qualified(source_doctype)
        if source_domain && source_domain != owning_domain && source_doctype_unq
          unless Grants::Registry.active?(db, owning_domain, source_domain, source_doctype_unq)
            Log.info do
              "Hook '#{hook.id}' on '#{owning_domain}' skipped — no active grant " \
              "from '#{source_domain}' on '#{source_doctype}'"
            end
            return
          end
        end

        # The cause template binds every write the hook's Lua performs to
        # the source mutation: kind/name name the hook, `parent` is the
        # source mutation id, `trace` is inherited from the source cause
        # (falling back to the source mutation id) so the whole cluster
        # — request → action → hook → hook writes — groups under one id.
        source_mut_id = msg.headers["mutation_id"]?.try(&.as_s?)
        inherited_trace = msg.headers["cause"]?.try(&.as_h?).try { |c| c["trace"]?.try(&.as_s?) }
        cause = Mutation::Cause.new(
          kind: Mutation::CauseKind::HookEvent,
          name: hook.id,
          event: event_name,
          source: "#{source_doctype}:#{source_id}",
          parent: source_mut_id,
          trace: inherited_trace || source_mut_id,
        )
        payload = build_event_payload(db, owning_domain, msg, source_doctype, source_id, event_name)

        Executor.new(db, owning_domain, hook, cause: cause) do |executor|
          errors = executor.run_event(payload)
          unless errors.empty?
            Log.warn do
              "Hook '#{hook.id}' on '#{owning_domain}' reported " +
                "#{errors.size} validation error(s) for #{source_doctype}##{source_id}: " +
                "#{errors.map(&.message).join("; ")}"
            end
          end
        end
      rescue ex : Executor::Error
        # Lua syntax/runtime error — the script itself is broken. Logged
        # and skipped; the registry's fail-closed parse keeps the bad
        # script out of the system at authoring time, but a runtime
        # error (nil deref, etc.) still surfaces here.
        Log.error do
          "Hook '#{hook.id}' on '#{owning_domain}' raised Lua error on " +
            "#{source_doctype}##{source_id}: #{ex.message}"
        end
      rescue ex : Exception
        Log.error { "Hook '#{hook.id}' on '#{owning_domain}' failed: #{ex.message}" }
      end

      # ── Payload construction ────────────────────────────────────────

      # Builds the `ctx.event` payload from the message. Carries the
      # source mutation's identity, event, document content, and the
      # actioner that triggered it — so the common case (inspect the
      # source document) does not need a cross-domain `document.get`.
      #
      # The bus payload of a document event is the id-only frame, so the
      # handler loads the live document body here — one read per hook
      # fire. A missing or tombstoned source keeps the id-only frame;
      # the event still delivers. An opt-in event (`child_changed`,
      # `notified`, the job-lifecycle events) carries its own payload on
      # the bus, so the handler delivers it as it arrived and does no
      # load.
      #
      # The content is grant-projected: a foreign source hands the hook
      # only the fields whose tags the owning domain's grant covers
      # (untagged fields resolve to `["default"]`). Same-domain events
      # keep full content. The projection runs after the body load, so
      # the mask applies to the live body.
      private def build_event_payload(
        db : DB::Connection,
        owning_domain : String,
        msg : Facet::Event::Message,
        source_doctype : String,
        source_id : String,
        event_name : String,
      ) : JSON::Any
        headers = msg.headers
        source_domain, source_doctype_unq = parse_qualified(source_doctype)

        content = msg.content
        if source_domain && source_doctype_unq && !Facet::Event.opt_in_event?(event_name)
          content = fetch_live_content(db, source_domain, source_doctype_unq, source_id) || content
        end
        if source_domain && source_doctype_unq && source_domain != owning_domain
          content = Grants::Registry.project(db, owning_domain, source_domain, source_doctype_unq, content)
        end

        h = {} of String => JSON::Any
        h["domain"] = JSON::Any.new(source_domain || "")
        h["doc_type"] = JSON::Any.new(source_doctype_unq || source_doctype)
        h["event"] = JSON::Any.new(event_name)
        h["doc_id"] = JSON::Any.new(source_id)
        h["mutation_id"] = headers["mutation_id"]? || JSON::Any.new(nil.as(JSON::Any::Type))
        h["actioner_id"] = headers["actioner_id"]? || JSON::Any.new(nil.as(JSON::Any::Type))
        h["content"] = content
        JSON::Any.new(h)
      end

      # Loads the body of the live source document. Returns `nil` when the
      # row is missing or tombstoned — the caller keeps the id-only frame
      # from the bus in that case.
      private def fetch_live_content(
        db : DB::Connection,
        domain : String,
        doc_type : String,
        doc_id : String,
      ) : JSON::Any?
        db.query_one?(
          "SELECT content FROM projections WHERE domain = $1 AND doc_type = $2 AND id = $3 AND deleted_at IS NULL",
          domain, doc_type, doc_id,
          as: JSON::Any,
        )
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
