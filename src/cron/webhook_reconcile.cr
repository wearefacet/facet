# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "json"
require "../database"
require "../config"
require "../event/message"
require "../mutation/provenance"
require "../webhook/manager"
require "../webhook/handler"
require "../webhook/registry"

module Facet
  module Cron
    # At-least-once backstop for the webhook **enqueue hop**.
    #
    # Event delivery is at-most-once by decision (`doc/backend/event.md` →
    # Delivery contract): a publish-time
    # failure (`Event::Publisher.flush` rescue), a consumer-side handler
    # error, consumer downtime, or a stream trim each lose the event with
    # one log line. Webhooks carry external obligations, so this cron
    # repairs the one hop that matters — the `Webhook::Handler` enqueue
    # decision — by re-running it for recent mutations that produced no
    # `webhook_delivery` row. The transport after enqueue is already
    # durable (`Jobs`: PG rows, leases, atomic retry).
    #
    # Because it derives from `mutations` (the durable log), one pass
    # covers every loss mode at once. No delivery state is added to
    # `mutations`; the reconciler **derives, it does not mark**.
    #
    # ## Algorithm
    #
    # 1. Select the window's document mutations (`domain <> 'core'`,
    #    `cause_kind` outside the excluded set), ordered by `emitted_at` so
    #    repaired deliveries keep causal order within the window.
    # 2. Skip reentrant clusters — the own-kind check for hook /
    #    replication writes, plus the cluster-root lookup for their
    #    cascade children (see `reentrant?`).
    # 3. Derive the event name from the mutation row (see
    #    `derive_event_name` — the reconciler never invents a name; a row
    #    outside the map is skipped with a debug log).
    # 4. Keep rows with at least one binding on their source doctype, then
    #    build the per-mutation skip set: bindings already enqueued (a
    #    `webhook_delivery` job row in **any** status — a failed row has
    #    exhausted its retries, and re-enqueueing would bypass the retry
    #    policy) and bindings created after the mutation (a new webhook
    #    receives events from mutations after its creation, close to the
    #    stream's "new groups start at `$`" semantics).
    # 5. Build one synthetic `Event::Message` per mutation — the same
    #    shape the stream delivers — and call the shared
    #    `Webhook::Handler#call`. Matching, the event filter,
    #    `Webhook::AuthCheck`, and enqueue stay in one place; the
    #    reconciler holds no copy of the decision logic.
    #
    # ## Bounds
    #
    # The reconciler covers document-mutation events on non-`core` domains
    # within the window. It does not cover `notified` (recipient-scoped,
    # payload-override), `child_changed` (aggregate envelopes keyed to the
    # parent), the four import/export job-lifecycle events (they originate
    # from `background_jobs` rows, not mutations), or mutations older than
    # `webhook.reconcile_window_hours`. See `doc/backend/webhook.md` →
    # Reconciler.
    class WebhookReconcile
      Log = ::Log.for("facet.cron.webhook_reconcile")

      # Cause kinds whose mutations carry `reentrant: true` on the stream.
      # The webhook handler skips those events; the reconciler must reach
      # the same verdict.
      REENTRANT_KINDS = Set{"hook_event", "hook_schedule", "replication"}

      # One window row with its cluster root's cause kind resolved.
      record WindowMutation,
        id : String,
        domain : String,
        doc_type : String,
        doc_id : String,
        action : String,
        actioner_id : String,
        cause_kind : String,
        cause_name : String?,
        cause_event : String?,
        cause_source : String?,
        cause_parent : String?,
        cause_trace : String,
        emitted_at : Time,
        root_cause_kind : String?

      # Runs one reconciliation pass.
      def self.call : Nil
        manager = Webhook::Manager.instance
        if manager.nil?
          Log.info { "Webhook manager not installed — nothing to reconcile" }
          return
        end

        window_hours = Facet::Config.instance.webhook.reconcile_window_hours
        handler = Webhook::Handler.new(manager.registry)

        repaired = 0
        Facet::Database.with_db do |db|
          before = delivery_count(db)
          reconcile(db, handler, manager.registry, window_hours)
          repaired = delivery_count(db) - before
        end
        Log.info { "Webhook reconcile pass complete: #{repaired} delivery job(s) enqueued" } if repaired.positive?
      rescue ex : Exception
        # The scheduler logs and reschedules; re-raise so the task's own
        # span attributes reflect the failure if telemetry is wired.
        Log.error { "Webhook reconcile pass failed: #{ex.message}" }
        raise ex
      end

      # ── Pass ───────────────────────────────────────────────────────────

      private def self.reconcile(
        db : DB::Connection,
        handler : Webhook::Handler,
        registry : Webhook::Registry,
        window_hours : Int32,
      ) : Nil
        rows = fetch_window_mutations(db, window_hours)

        # Only rows whose source doctype has at least one binding can
        # produce a delivery — filter before the dedupe query so the
        # `ANY($1)` array stays bounded by the webhook-relevant subset.
        # One registry read per doctype (the registry returns a copy per
        # call), shared by the filter and the per-row skip sets.
        bindings_by_doctype = {} of String => Array(Webhook::Registry::Binding)
        candidates = [] of WindowMutation
        rows.each do |row|
          doctype = qualified(row)
          bindings = bindings_by_doctype[doctype]? || registry.webhooks_for(doctype)
          next if bindings.empty?

          bindings_by_doctype[doctype] = bindings
          candidates << row
        end
        return if candidates.empty?

        enqueued = enqueued_pairs(db, candidates.map(&.id))

        candidates.each do |row|
          next if reentrant?(row)

          event_name = derive_event_name(row)
          if event_name.nil?
            Log.debug do
              "No event-name map row for mutation #{row.id} " \
              "(action=#{row.action}, cause_kind=#{row.cause_kind}) — skipped"
            end
            next
          end

          bindings = bindings_by_doctype[qualified(row)]
          skip = skip_set(row, bindings, enqueued)
          # Nothing left to decide when every binding on this doctype is
          # already skipped — spare the handler call and its transaction.
          next if bindings.all? { |binding| skip.includes?(binding.id) }

          handler.call(build_message(row, event_name), skip)
        end
      end

      # ── Selection ───────────────────────────────────────────────────────

      # Returns the window's document mutations in emission order, each
      # carrying its cluster root's `cause_kind`. `domain <> 'core'`:
      # `core.DocType` uses `registered` / `updated`, so the
      # action→event map does not hold there. `periodic_snapshot` (the
      # trigger's own rows — nothing is published for them) and
      # `webhook_test` (the test path) are excluded. The root lookup is a
      # lateral join on `idx_mutations_cause_trace` — for a root mutation
      # the root is the row itself; for a cascade child it is the
      # earliest-emitted member of the shared trace.
      private def self.fetch_window_mutations(db : DB::Connection, window_hours : Int32) : Array(WindowMutation)
        db.query_all(
          <<-SQL,
            SELECT m.id, m.domain, m.doc_type, m.doc_id, m.action, m.actioner_id,
                   m.cause_kind, m.cause_name, m.cause_event, m.cause_source,
                   m.cause_parent, m.cause_trace, m.emitted_at,
                   root.cause_kind AS root_cause_kind
            FROM mutations m
            LEFT JOIN LATERAL (
              SELECT r.cause_kind
              FROM mutations r
              WHERE r.cause_trace = m.cause_trace
              ORDER BY r.emitted_at, r.id
              LIMIT 1
            ) root ON true
            WHERE m.domain <> 'core'
              AND m.emitted_at >= now() - ($1 * interval '1 hour')
              AND m.cause_kind NOT IN ('periodic_snapshot', 'webhook_test')
            ORDER BY m.emitted_at, m.id
          SQL
          window_hours,
        ) do |rs|
          WindowMutation.new(
            id: rs.read(String),
            domain: rs.read(String),
            doc_type: rs.read(String),
            doc_id: rs.read(String),
            action: rs.read(String),
            actioner_id: rs.read(String),
            cause_kind: rs.read(String),
            cause_name: rs.read(String?),
            cause_event: rs.read(String?),
            cause_source: rs.read(String?),
            cause_parent: rs.read(String?),
            cause_trace: rs.read(String),
            emitted_at: rs.read(Time),
            root_cause_kind: rs.read(String?),
          )
        end
      end

      # The dedupe authority: one query per pass builds the set of
      # already-enqueued (mutation_id, webhook_id) pairs. A pair with a
      # job row in **any** status counts as enqueued — a failed row has
      # exhausted its retries, and re-enqueueing would bypass the retry
      # policy. `background_jobs` is the authority, not `webhook_calls`:
      # a pending job has no call row yet. The query is a sequential scan;
      # the table is pruned to `jobs.retention_days`, and the window must
      # stay below that horizon (validated at config load).
      private def self.enqueued_pairs(db : DB::Connection, mutation_ids : Array(String)) : Hash(String, Set(String))
        pairs = Hash(String, Set(String)).new { |h, k| h[k] = Set(String).new }
        return pairs if mutation_ids.empty?

        db.query_all(
          <<-SQL,
            SELECT payload->>'mutation_id' AS mutation_id,
                   payload->>'webhook_id'  AS webhook_id
            FROM background_jobs
            WHERE kind = 'webhook_delivery'
              AND payload->>'mutation_id' = ANY($1)
          SQL
          mutation_ids,
        ) do |rs|
          mutation_id = rs.read(String?)
          webhook_id = rs.read(String?)
          next if mutation_id.nil? || webhook_id.nil?
          pairs[mutation_id] << webhook_id
        end
        pairs
      end

      # ── Per-row decisions ───────────────────────────────────────────────

      # True when the stream path would have carried `reentrant: true` —
      # the webhook handler skips those events, so the reconciler must
      # reach the same verdict.
      #
      # Two checks, because the flag propagates along different shapes:
      #
      # - the own-kind check catches hook and replication writes — their
      #   rows carry the reentrant kind directly;
      # - the cluster-root check catches cascade children under a
      #   reentrant delete — they carry `cause_kind = 'cascade'` but
      #   inherit the parent's flag (`Document::Delete` passes
      #   `reentrant: reentrant` down the cascade), so the own-kind check
      #   alone is wrong for them. The root lookup resolves the trace to
      #   its earliest-emitted member: for a schedule-hook fire the root
      #   is the hook's own write (`hook_schedule`), so its cascade
      #   children are caught.
      private def self.reentrant?(row : WindowMutation) : Bool
        return true if REENTRANT_KINDS.includes?(row.cause_kind)
        root_kind = row.root_cause_kind
        !root_kind.nil? && REENTRANT_KINDS.includes?(root_kind)
      end

      # Derives the event name the mutation published. The map is the
      # contract between the mutation row and the stream — the reconciler
      # never invents a name. A row outside the map returns nil (skipped
      # with a debug log). Code that enqueues a bespoke event name for a
      # standard document mutation must carry the name in `cause_event`
      # or extend this map.
      private def self.derive_event_name(row : WindowMutation) : String?
        case row.action
        when "create" then ::Facet::Event::CREATED
        when "delete" then ::Facet::Event::DELETED
        when "update"
          # The action's own mutation carries the action's event name in
          # `cause_event`. Nested writes under the action (via Lua
          # `document.*` helpers) inherit the cause — kind `action`, event
          # set, `cause_parent` bound to the driving mutation — but
          # `Document::Update` publishes the standard `updated` for them,
          # so the parentless check keeps the two shapes apart.
          if row.cause_kind == "action" && row.cause_event && row.cause_parent.nil?
            row.cause_event
          else
            ::Facet::Event::UPDATED
          end
        when "snapshot"
          case {row.cause_kind, row.cause_event}
          when {"migration", ::Facet::Event::MIGRATED}   then ::Facet::Event::MIGRATED
          when {"rollback", ::Facet::Event::ROLLED_BACK} then ::Facet::Event::ROLLED_BACK
          else
            nil
          end
        else
          nil
        end
      end

      # Builds the per-mutation skip set: the dedupe pairs for this
      # mutation plus every binding created after the mutation was
      # emitted (a new webhook receives events from mutations after its
      # creation — it does not receive the window's history).
      private def self.skip_set(
        row : WindowMutation,
        bindings : Array(Webhook::Registry::Binding),
        enqueued : Hash(String, Set(String)),
      ) : Set(String)
        skip = Set(String).new
        skip.concat(enqueued[row.id]? || Set(String).new)
        bindings.each do |binding|
          skip << binding.id if row.emitted_at < binding.created_at
        end
        skip
      end

      # Builds the synthetic message in the shape the stream delivers:
      # headers `domain`, `doc_type`, `mutation_id`, `actioner_id`,
      # `cause` (rebuilt from the typed cause columns), `event`, and
      # `emitted_at` (so a repaired delivery keeps its original emission
      # instant); content `{"id": doc_id}` — document events use the
      # default payload, no document service passes `payload:`.
      private def self.build_message(row : WindowMutation, event_name : String) : Facet::Event::Message
        headers = {
          "domain"      => JSON::Any.new(row.domain),
          "doc_type"    => JSON::Any.new(row.doc_type),
          "event"       => JSON::Any.new(event_name),
          "mutation_id" => JSON::Any.new(row.id),
          "actioner_id" => JSON::Any.new(row.actioner_id),
          "emitted_at"  => JSON::Any.new(row.emitted_at.to_rfc3339),
        } of String => JSON::Any

        if kind = Mutation::CauseKind.from_json_value(row.cause_kind)
          headers["cause"] = Mutation::Cause.new(
            kind: kind,
            name: row.cause_name,
            event: row.cause_event,
            source: row.cause_source,
            parent: row.cause_parent,
            trace: row.cause_trace
          ).to_json_any
        end

        Facet::Event::Message.new(
          content: JSON::Any.new({"id" => JSON::Any.new(row.doc_id)}),
          headers: headers,
        )
      end

      private def self.qualified(row : WindowMutation) : String
        "#{row.domain}.#{row.doc_type}"
      end

      private def self.delivery_count(db : DB::Connection) : Int64
        db.query_one(
          "SELECT count(*) FROM background_jobs WHERE kind = 'webhook_delivery'",
          as: Int64,
        )
      end
    end
  end
end
