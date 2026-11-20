# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "json"
require "../event/message"
require "../database"
require "../event/publisher"
require "../jobs/manager"
require "../util/script_helpers"
require "./registry"
require "./dispatcher"
require "./auth_check"

module Facet
  module Webhook
    # Async source-event handler that enqueues one `webhook_delivery` job
    # per matching `core.Webhook` binding.
    #
    # Registered as the no-filter subscription callback on the webhook
    # `Event::Manager` (one consumer group per instance, subscribed to
    # source doctype streams). On each incoming `Message` it:
    #
    # 1. **Reentrancy skip** — `headers["reentrant"] == true` messages are
    #    ACKed and dropped. This is the event-loop side of the cycle gate;
    #    the outbound side is the `X-Facet-Origin` header the dispatcher
    #    sends (decision 5).
    # 2. **Resolve source** — `headers["domain"]` + `headers["doc_type"]` +
    #    `content["id"]` + `headers["event"]`.
    # 3. **Registry lookup** — `webhooks_for(source_doctype)`; empty → done.
    # 4. **Event filter** — a binding's `events` is `nil` (match all) or an
    #    explicit list; an empty list matches nothing.
    # 5. **Enqueue-time RBAC check + enqueue** — for each surviving binding,
    #    the six-step check (decision 8, `Webhook::AuthCheck`) runs on one
    #    DB connection; a pass enqueues one `webhook_delivery` row. The
    #    whole loop runs inside one transaction, so a crash mid-loop rolls
    #    every enqueue in the batch back (all-or-nothing). Each binding is
    #    decided independently.
    # 6. **Flush** — `Event::Publisher.flush` so downstream consumers see
    #    events immediately (mirrors `Hooks::Handler`).
    #
    # ## Reconciler path
    #
    # `Cron::WebhookReconcile` calls the same `#call` with a synthetic
    # `Event::Message` derived from a `mutations` row, passing
    # `skip_webhook_ids` — the per-mutation set of bindings that must not
    # produce a row (already enqueued, or created after the mutation). The
    # stream path passes nothing; the default empty set changes nothing.
    # A reconciler message may carry an `emitted_at` header (RFC 3339);
    # it rides onto the job payload so a repaired delivery keeps its
    # original emission instant and receivers can detect and reorder.
    #
    # ACK-on-arrival (the underlying `Subscriber::Stream` runs with
    # `no_ack: true`) — a transient DB error during enqueue is permanent
    # until the next source mutation (logged, not retried), same stance as
    # `Hooks::Handler`. The webhook enqueue hop is the one exception with a
    # repair path: `Cron::WebhookReconcile` re-runs this decision from the
    # durable `mutations` log.
    #
    # The check is the load-bearing security gate: a revoked binding or an
    # unreadable source document produces no job row. The execute-time
    # dispatcher does no RBAC and no projection reads.
    class Handler
      Log = ::Log.for("facet.webhook.handler")

      def initialize(@registry : Registry)
      end

      # Entry point — invoked by the `Event::Manager` for each message on a
      # source doctype stream.
      #
      # `skip_webhook_ids` names bindings that are dropped before the RBAC
      # gate and the enqueue — the reconciler's dedupe and new-binding
      # bound. The stream path leaves it empty.
      def call(msg : Facet::Event::Message, skip_webhook_ids : Set(String) = Set(String).new) : Nil
        # 1. Reentrancy gate.
        if reentrant?(msg)
          Log.debug { "Skipping reentrant event on #{source_descriptor(msg)}" }
          return
        end

        # 2. Resolve source identity.
        source_domain, source_doc_type, source_id, event_name = resolve_source(msg)
        return if source_domain.nil? || source_doc_type.nil? || source_id.nil?

        # 3. Registry lookup.
        bindings = @registry.webhooks_for("#{source_domain}.#{source_doc_type}")
        return if bindings.empty?

        # 4. Event filter per binding. The `notified` event is opt-in:
        #    it fires only for bindings whose `events` list names it
        #    explicitly. A match-all binding (`events` absent) must not
        #    receive it — a notification is private to its recipient, and
        #    a pre-existing all-events webhook never signed up for it.
        matching = bindings.select { |binding| binding_matches?(binding, event_name.as(String)) }
        # Reconciler skips (dedupe / new-binding bound) run before the RBAC
        # gate — a binding in the set produces no row and no AuthCheck.
        matching.reject! { |binding| skip_webhook_ids.includes?(binding.id) }
        return if matching.empty?

        # 5. One transaction around the whole loop — a crash mid-loop rolls
        #    every enqueue in this batch back.
        Database.with_transaction(:read_write) do |db|
          matching.each do |binding|
            enqueue_one(
              db, binding,
              source_domain.as(String), source_doc_type.as(String),
              source_id.as(String), event_name.as(String), msg,
            )
          end
        end

        # 6. Flush so downstream consumers see the events immediately —
        #    the handler runs outside the HTTP layer's post-commit flush.
        Facet::Event::Publisher.flush
      rescue ex : Exception
        # Logged, not retried — see class docs. The next source mutation
        # retriggers and catches up; the reconciler repairs the hop within
        # its window.
        Log.error { "Webhook handler error: #{ex.message}\n#{ex.backtrace?.try(&.join('\n'))}" }
        Facet::Event::Loss.record_dropped_message
      end

      # ── Per-binding enqueue ────────────────────────────────────────────

      private def enqueue_one(
        db : DB::Connection,
        binding : Registry::Binding,
        source_domain : String,
        source_doc_type : String,
        source_id : String,
        event_name : String,
        msg : Facet::Event::Message,
      ) : Nil
        result = AuthCheck.call(db, binding.id, source_domain, source_doc_type, source_id, event_name, msg.content)
        unless result.is_a?(AuthCheck::Pass)
          Log.info do
            "Webhook '#{binding.id}' skipped (#{AuthCheck.skip_label(result)}): " \
            "#{source_domain}.#{source_doc_type}##{source_id} (#{event_name})"
          end
          return
        end

        payload = Payload.new(
          webhook_id: binding.id,
          delivery_id: Util::ScriptHelpers.ulid,
          event: event_name,
          domain: source_domain,
          doc_type: source_doc_type,
          doc_id: source_id,
          mutation_id: header_string(msg, "mutation_id"),
          actioner_id: header_string(msg, "actioner_id"),
          cause: msg.headers["cause"]?,
          content: msg.content,
          # A reconciler message carries the mutation's original emission
          # instant in this header; the stream path leaves it absent and
          # the enqueue stamps `now`.
          emitted_at: header_string(msg, "emitted_at") || Time.utc.to_rfc3339,
          url: result.url,
          secret: result.secret,
          headers: result.headers,
        )

        mgr = Jobs::Manager.instance
        if mgr.nil?
          Log.warn { "Jobs::Manager not installed — no webhook_delivery row for '#{binding.id}'" }
          return
        end
        mgr.enqueue(
          "webhook_delivery",
          JSON.parse(payload.to_json),
          max_attempts: Config.instance.webhook.max_attempts,
          backoff: Config.instance.webhook.backoff_seconds,
        )
        Log.info do
          "Webhook '#{binding.id}' enqueued webhook_delivery #{payload.delivery_id} " \
          "for #{source_domain}.#{source_doc_type}##{source_id} (#{event_name})"
        end
      end

      # ── Message helpers (mirrors Hooks::Handler) ───────────────────────

      # The per-binding event filter. A binding's `events` is `nil` (match
      # all) or an explicit list; an empty list matches nothing. The
      # opt-in events (`notified`, plus the four import/export job
      # lifecycle events) fire solely for bindings that name them
      # explicitly — a pre-existing all-events webhook never signed up for
      # notification privacy or job lifecycle noise.
      private def binding_matches?(binding : Registry::Binding, event_name : String) : Bool
        events = binding.events
        if ::Facet::Event.opt_in_event?(event_name)
          !events.nil? && events.includes?(event_name)
        else
          events.nil? || events.includes?(event_name)
        end
      end

      private def reentrant?(msg : Facet::Event::Message) : Bool
        msg.headers["reentrant"]?.try(&.as_bool?) == true
      end

      private def resolve_source(msg : Facet::Event::Message) : {String?, String?, String?, String?}
        headers = msg.headers
        domain = headers["domain"]?.try(&.as_s?)
        doc_type = headers["doc_type"]?.try(&.as_s?)
        event = headers["event"]?.try(&.as_s?) || "unknown"
        source_id = msg.content["id"]?.try(&.as_s?)

        return {nil, nil, nil, nil} if domain.nil? || doc_type.nil? || source_id.nil?

        {domain, doc_type, source_id, event}
      end

      private def header_string(msg : Facet::Event::Message, key : String) : String?
        msg.headers[key]?.try(&.as_s?)
      end

      private def source_descriptor(msg : Facet::Event::Message) : String
        domain = msg.headers["domain"]?.try(&.as_s?) || "?"
        doc_type = msg.headers["doc_type"]?.try(&.as_s?) || "?"
        event = msg.headers["event"]?.try(&.as_s?) || "?"
        id = msg.content["id"]?.try(&.as_s?) || "?"
        "#{domain}.#{doc_type}##{id} (#{event})"
      end
    end
  end
end
