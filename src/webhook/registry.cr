# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "json"
require "pg"
require "../database"
require "../util/cache_freshness"

module Facet
  module Webhook
    # Static map of `core.Webhook` bindings, keyed by **source doctype**.
    #
    # Built lazily, then kept in sync with `core.Webhook` mutations via the
    # same **stale-flag / lazy-rebuild** model as `Hooks::Registry`: the
    # `DoctypeCache` Pub/Sub subscriber marks the registry stale on every
    # `fanout:core.Webhook:*` event, and the next read (`webhooks_for`,
    # `source_selectors`) rebuilds from the DB on demand. Events never
    # rebuild, they only signal staleness; each node recovers via its own
    # DB query and re-caches. A lost fanout (a mutation published while
    # Redis was down) is bounded by `cache.staleness_ttl_s` — see
    # `Util::CacheFreshness`.
    #
    # ## Key shape
    #
    # One webhook watches exactly one source doctype (v1 — no domain-wide
    # selector), so keys are plain qualified doctype names:
    #
    # - `"accountancy.Contract"` — matches only events on
    #   `accountancy.Contract`.
    #
    # The stored `source_doctype` value is a reference token: the field
    # targets `core.DocType` (B-54), a `core.DocType` document's id is the
    # qualified doctype name, so `qa.Widget` persists as
    # `core.DocType.qa.Widget`. `build` strips the declared-target prefix
    # so the key — and every stream subscription, handler lookup, and
    # reconciler read derived from it — carries the same bare form the
    # event publisher writes (`FACET:RESOURCE:qa:Widget$N`).
    #
    # `webhooks_for("accountancy.Contract")` returns every enabled, live
    # webhook bound to that doctype.
    #
    # ## Draft isolation
    #
    # A webhook whose `source_doctype` lives in a **draft** (or otherwise
    # not served) domain never enters this registry — the `domain_enabled?`
    # predicate (same one hooks and replication use) excludes it at build
    # time. Once the source domain is published, the next lazy rebuild
    # picks the webhook up.
    #
    # ## Fail-closed parsing
    #
    # One corrupt projection row never blocks the rest: a webhook missing
    # `source_doctype` (or `secret`, which makes signing impossible) is
    # logged and skipped, and the remaining rows still load. This mirrors
    # `Hooks::Registry`'s "drop broken bindings" stance: the authoring
    # engine is the hard gate; the registry is the runtime safety net.
    #
    # The registry owns only the **static bindings**. It does not load the
    # bound `iam.Account` / `iam.Roles` projections — the handler reads
    # them per event (enqueue-time RBAC, decision 8) — and the handler
    # re-reads `url` / `secret` / `headers` from the projection at enqueue
    # time (decision 4). Bindings carry identity and the `events` filter.
    class Registry
      Log = ::Log.for("facet.webhook.registry")

      # The declared reference target of the `core.Webhook.source_doctype`
      # field. Reference fields persist as qualified tokens
      # (`{target_doctype}.{id}` — `ReferenceType#normalize`), so the
      # registry strips this prefix to recover the bare qualified doctype
      # the event publisher keys streams by.
      REFERENCE_PREFIX = "core.DocType."

      record Binding,
        id : String,             # the core.Webhook document id
        source_doctype : String, # qualified, e.g. "accountancy.Contract"
        events : Array(String)?, # nil = match all
        secret : String,         # per-webhook signing key
        account_id : String?,    # bound iam.Account (enqueue-time RBAC)
        role_id : String?,       # bound iam.Roles (enqueue-time RBAC)
        created_at : Time        # projection creation instant — the reconciler's new-binding bound

      @webhooks : Hash(String, Array(Binding))
      @mutex : Mutex
      @stale : Bool
      @built_at : Time::Instant?

      def initialize(@domain_enabled : String -> Bool = default_domain_enabled)
        @webhooks = {} of String => Array(Binding)
        @mutex = Mutex.new
        @stale = true
        @built_at = nil
      end

      # Returns `true` while the registry has been marked stale and the
      # next read will trigger a lazy rebuild.
      def stale? : Bool
        @mutex.synchronize { @stale }
      end

      # Marks the registry as stale without rebuilding. Called by the
      # `DoctypeCache` Pub/Sub subscriber on every `fanout:core.Webhook:*`
      # event. The next read triggers a lazy rebuild from the DB. The flag
      # is idempotent (set-true), so N events produce exactly one rebuild.
      def mark_stale : Nil
        @mutex.synchronize { @stale = true }
      end

      # Rebuilds the binding map from every non-deleted `core.Webhook`
      # projection. Disabled webhooks, corrupt rows, and webhooks whose
      # source doctype lives in a domain the `domain_enabled?` predicate
      # rejects (drafts — decision 1, "Webhooks on a draft domain") are
      # excluded.
      def build(db : DB::Connection) : Nil
        rebuilt = {} of String => Array(Binding)

        fetch_webhooks(db).each do |row|
          next unless row[:enabled] == "true"

          source_doctype = strip_reference_prefix(row[:source_doctype])
          if source_doctype.nil? || source_doctype.empty?
            Log.warn { "Webhook '#{row[:id]}' has no source_doctype — skipped" }
            next
          end

          # Source domain = the part before the `.` in the qualified
          # doctype. Malformed selectors are dropped fail-closed.
          source_domain = source_doctype.split('.', 2)
          if source_domain.size != 2 || source_domain[0].empty? || source_domain[1].empty?
            Log.warn { "Webhook '#{row[:id]}' has malformed source_doctype '#{source_doctype}' — skipped" }
            next
          end
          next unless @domain_enabled.call(source_domain[0])

          secret = row[:secret]
          if secret.nil? || secret.empty?
            Log.warn { "Webhook '#{row[:id]}' has no secret — skipped (signing impossible)" }
            next
          end

          binding = Binding.new(
            id: row[:id],
            source_doctype: source_doctype,
            events: parse_events(row[:events]),
            secret: secret,
            account_id: row[:account_id],
            role_id: row[:role_id],
            created_at: row[:created_at],
          )
          (rebuilt[source_doctype] ||= [] of Binding) << binding
        end

        @mutex.synchronize { @webhooks = rebuilt; @stale = false; @built_at = Time.instant }

        Log.info do
          total = rebuilt.values.sum(&.size)
          "Webhook registry rebuilt: #{total} binding(s) across #{rebuilt.size} source doctype(s)"
        end
      end

      # Returns every binding whose source doctype matches the given
      # qualified doctype (e.g. `"accountancy.Contract"`). Triggers a lazy
      # rebuild from the DB if the registry has been marked stale since
      # the last build.
      def webhooks_for(source_doctype : String) : Array(Binding)
        ensure_fresh
        @mutex.synchronize { @webhooks.fetch(source_doctype, [] of Binding).dup }
      end

      # Distinct source doctypes this instance must subscribe to. Each key
      # is a fully-qualified doctype (`"accountancy.Contract"`). Triggers a
      # lazy rebuild if the registry is stale.
      def source_selectors : Set(String)
        ensure_fresh
        @mutex.synchronize do
          set = Set(String).new
          @webhooks.each_key { |k| set << k }
          set
        end
      end

      # ── Stale-flag / lazy-rebuild ──────────────────────────────────────

      # Rebuilds from the DB if stale, or if the last successful build is
      # older than the staleness bound (`Util::CacheFreshness`) — the
      # safety net for a lost fanout. A failed rebuild is logged and the
      # cached state is served — `@stale` stays `true` so the next read
      # retries. Mirrors `Hooks::Registry#ensure_fresh`. The rebuild
      # only reads, so it asks for the ro pin (reusing the caller's rw pin
      # on a write entry point — no second checkout there).
      private def ensure_fresh : Nil
        needs_rebuild = @mutex.synchronize { @stale || Util::CacheFreshness.expired?(@built_at) }
        return unless needs_rebuild
        Database.with_db(:read_only) { |db| build(db) }
      rescue ex : Exception
        Log.warn { "Lazy webhook registry rebuild failed (serving cached state): #{ex.message}" }
      end

      # ── Private ──────────────────────────────────────────────────────

      # Strips the declared reference-target prefix from a stored
      # `source_doctype` token (`core.DocType.qa.Widget` → `qa.Widget`).
      # A value stored without the prefix — the bare qualified doctype —
      # passes through unchanged.
      private def strip_reference_prefix(raw : String?) : String?
        return raw if raw.nil?
        raw.starts_with?(REFERENCE_PREFIX) ? raw[REFERENCE_PREFIX.size..] : raw
      end

      # Normalizes the stored `events` value into a match-all / match-none
      # filter:
      #
      # - `nil` or a non-array value → `nil` (match every event). A missing
      #   key means the webhook opted into everything.
      # - an explicit empty array → `[]` (match nothing). A webhook that
      #   declares `events: []` opted out of all events and must never
      #   fire; the binding still loads so the handler can filter on it.
      # - a non-empty array → its string members.
      private def parse_events(raw : JSON::Any?) : Array(String)?
        return nil if raw.nil?
        arr = raw.as_a?
        return nil if arr.nil?
        arr.compact_map(&.as_s?)
      end

      # Fetches the static fields of every non-deleted `core.Webhook`
      # projection. `url` / `headers` are deliberately not read — the
      # handler re-reads them (and `secret`) from the projection at
      # enqueue time (decision 4). `created_at` is the projection row's
      # creation instant — `Cron::WebhookReconcile` uses it to bound a new
      # webhook to mutations emitted after its creation.
      private def fetch_webhooks(db : DB::Connection)
        db.query_all(
          <<-SQL
            SELECT id,
                   content->>'source_doctype' AS source_doctype,
                   COALESCE(content->>'enabled', 'true') AS enabled,
                   content->'events'          AS events,
                   content->>'secret'         AS secret,
                   content->>'account_id'     AS account_id,
                   content->>'role_id'        AS role_id,
                   created_at
            FROM projections
            WHERE domain = 'core' AND doc_type = 'Webhook' AND deleted_at IS NULL
          SQL
        ) do |rs|
          {
            id:             rs.read(String),
            source_doctype: rs.read(String?),
            enabled:        rs.read(String),
            events:         rs.read(JSON::Any?),
            secret:         rs.read(String?),
            account_id:     rs.read(String?),
            role_id:        rs.read(String?),
            created_at:     rs.read(Time),
          }
        end
      end

      private def default_domain_enabled : String -> Bool
        ->(domain : String) { Facet::Config.instance.domain_enabled?(domain) }
      end
    end
  end
end
