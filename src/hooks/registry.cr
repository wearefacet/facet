# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "json"
require "pg"
require "../database"
require "../util/cache_freshness"
require "./definition"

module Facet
  module Hooks
    # Static map of `event` hook bindings, keyed by **source selector**.
    #
    # Built once at startup, then kept in sync with `core.Domain` mutations
    # via the same **stale-flag / lazy-rebuild** model as
    # `Replication::Registry`: the `DoctypeCache` Pub/Sub subscriber marks
    # the registry stale on every `fanout:core.Domain:*` event, and the
    # next read (`hooks_for`, `source_selectors`) rebuilds from the DB on
    # demand. Events never rebuild, they only signal staleness; each node
    # recovers via its own DB query and re-caches. A lost fanout (a
    # mutation published while Redis was down) is bounded by
    # `cache.staleness_ttl_s` — see `Util::CacheFreshness`.
    #
    # `schedule` hooks are indexed separately via `schedule_hooks` (a flat
    # list — they have no source doctype) and are dispatched by
    # `Hooks::Scheduler`. The keyed `@hooks` map below is the source of
    # truth for which source doctype streams the `event`-hook subscriber
    # must consume.
    #
    # ## Key shape
    #
    # Hooks are keyed by a selector string derived from their `source`:
    #
    # - `"accountancy.Contract"` — matches only events on `accountancy.Contract`.
    # - `"accountancy.*"` — matches events on any doctype in `accountancy`
    #   (when `source.doc_type` is omitted).
    #
    # `hooks_for("accountancy.Contract")` returns the union of the specific
    # and the domain-wide entries, in declaration order.
    #
    # ## Draft isolation
    #
    # Hooks declared on a **draft** domain are parsed and validated at
    # authoring time (by `Hooks::Validator` in `Document::Update`) but
    # never enter this registry — the `domain_enabled?` predicate (same
    # one replication uses) excludes them. Once the draft is published,
    # the next lazy rebuild picks the hooks up.
    #
    # ## Fail-closed parsing
    #
    # A malformed `hooks` array on a published domain is logged and the
    # offending entries are skipped — the rest of the domain's hooks still
    # load. This mirrors `Replication::Registry`'s "drop broken bindings"
    # stance: the authoring-time validator is the hard gate; the registry
    # is the runtime safety net that never hard-fails on one bad entry.
    class Registry
      Log = ::Log.for("facet.hooks.registry")

      @hooks : Hash(String, Array(Definition::Hook))
      @schedule_hooks : Array(Definition::Hook)
      @mutex : Mutex
      @stale : Bool
      @built_at : Time::Instant?

      def initialize(@domain_enabled : String -> Bool = default_domain_enabled)
        @hooks = {} of String => Array(Definition::Hook)
        @schedule_hooks = [] of Definition::Hook
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
      # `DoctypeCache` Pub/Sub subscriber on every `fanout:core.Domain:*`
      # event. The next read triggers a lazy rebuild from the DB. The flag
      # is idempotent (set-true), so N events produce exactly one rebuild.
      def mark_stale : Nil
        @mutex.synchronize { @stale = true }
      end

      # Rebuilds the hook map from all non-deleted, non-draft `core.Domain`
      # projections whose `hooks` array is present. Draft domains are
      # excluded via the `domain_enabled?` predicate (the authoritative
      # `draft = true` flag on `core.Domain`; the `_` cosmetic prefix is
      # never keyed off, mirroring `Replication::Registry#build`).
      #
      # Domain-wide hooks (`source.doc_type` omitted) are pre-expanded:
      # every doctype in the source domain is queried, and the hook is
      # indexed under each resulting `domain.Doctype` key. This matches
      # `Replication::Registry`'s exact-doctype keying, so the
      # subscription layer can use `source_selectors` directly as Redis
      # channel names without a separate wildcard expansion.
      def build(db : DB::Connection) : Nil
        rebuilt = {} of String => Array(Definition::Hook)

        domains = fetch_all_domains(db)
        rebuilt_schedule = [] of Definition::Hook

        domains.each do |domain_id, content|
          next unless @domain_enabled.call(domain_id)

          hooks, parse_errors = Definition.parse(content)
          parse_errors.each do |err|
            Log.warn { "Domain '#{domain_id}' hook parse error: #{err.message} (field: #{err.field || "<none>"})" }
          end

          hooks.each do |hook|
            # `schedule` hooks have no source doctype — collect them on the
            # flat `schedule_hooks` list for `Hooks::Scheduler`. Stamp the
            # owning domain so the scheduler can pin `document.*` writes.
            if hook.kind == :schedule
              rebuilt_schedule << hook.with_owning_domain(domain_id)
              next
            end
            next if hook.source_domain.nil?

            # Stamp the owning domain so `Hooks::Handler` can pin
            # `document.*` writes to it (decision 3).
            stamped = hook.with_owning_domain(domain_id)

            if stamped.source_doc_type
              # Specific doctype — index directly.
              key = "#{stamped.source_domain}.#{stamped.source_doc_type}"
              (rebuilt[key] ||= [] of Definition::Hook) << stamped
            else
              # Domain-wide — expand into every doctype in the source domain.
              doctypes_in_source = fetch_doctypes_in_domain(db, stamped.source_domain.as(String))
              if doctypes_in_source.empty?
                Log.debug { "Domain-wide hook '#{stamped.id}' on '#{domain_id}' has no doctypes in source domain '#{stamped.source_domain}' — not indexed" }
                next
              end
              doctypes_in_source.each do |dt|
                key = "#{stamped.source_domain}.#{dt}"
                (rebuilt[key] ||= [] of Definition::Hook) << stamped
              end
            end
          end
        end

        @mutex.synchronize { @hooks = rebuilt; @schedule_hooks = rebuilt_schedule; @stale = false; @built_at = Time.instant }

        Log.info do
          total = rebuilt.values.sum(&.size)
          "Hooks registry rebuilt: #{total} event hook(s) across #{rebuilt.size} source doctype(s), " \
          "#{rebuilt_schedule.size} schedule hook(s)"
        end
      end

      # Returns all `event` hooks whose source selector matches the given
      # source doctype (qualified, e.g. `"accountancy.Contract"`). Domain-wide
      # hooks (`source.doc_type` omitted) are pre-expanded into every
      # doctype key in their source domain at build time — so this lookup is a
      # single key fetch (no union logic at read time). Declaration order is
      # preserved per-key (specific hooks come before domain-wide hooks
      # because they are inserted in the order encountered during build).
      #
      # Triggers a lazy rebuild from the DB if the registry has been marked
      # stale since the last build.
      def hooks_for(source_doctype : String) : Array(Definition::Hook)
        ensure_fresh
        @mutex.synchronize { @hooks.fetch(source_doctype, [] of Definition::Hook).dup }
      end

      # Distinct source doctypes this instance must subscribe to. Each key
      # is a fully-qualified doctype (`"accountancy.Contract"`) — domain-wide
      # selectors are expanded to concrete doctype channels at build time.
      # Triggers a lazy rebuild if the registry is stale.
      def source_selectors : Set(String)
        ensure_fresh
        @mutex.synchronize do
          set = Set(String).new
          @hooks.each_key { |k| set << k }
          set
        end
      end

      # All `schedule` hooks across every published domain. `Hooks::Scheduler`
      # reads this on every poll so it picks up new/removed/changed schedule
      # hooks as the registry rebuilds lazily on `core.Domain` fanout
      # events. Hooks on draft domains are excluded by the `domain_enabled?`
      # predicate during `build` (decision: drafts never fire).
      def schedule_hooks : Array(Definition::Hook)
        ensure_fresh
        @mutex.synchronize { @schedule_hooks.dup }
      end

      # ── Stale-flag / lazy-rebuild ──────────────────────────────────────

      # Rebuilds from the DB if stale, or if the last successful build is
      # older than the staleness bound (`Util::CacheFreshness`) — the
      # safety net for a lost fanout. A failed rebuild is logged and the
      # cached state is served — `@stale` stays `true` so the next read
      # retries. Mirrors `Replication::Registry#ensure_fresh`. The rebuild
      # only reads, so it asks for the ro pin (reusing the caller's rw pin
      # on a write entry point — no second checkout there).
      private def ensure_fresh : Nil
        needs_rebuild = @mutex.synchronize { @stale || Util::CacheFreshness.expired?(@built_at) }
        return unless needs_rebuild
        Database.with_db(:read_only) { |db| build(db) }
      rescue ex : Exception
        Log.warn { "Lazy hooks registry rebuild failed (serving cached state): #{ex.message}" }
      end

      # ── Private ──────────────────────────────────────────────────────

      private def parse_qualified(qualified : String) : {String?, String?}
        parts = qualified.split('.', 2)
        if parts.size == 2
          {parts[0], parts[1]}
        else
          {nil, nil}
        end
      end

      # Fetches the id and content of every non-deleted, non-draft
      # `core.Domain` projection. Drafts are filtered by the `draft`
      # content flag (the authoritative signal), mirroring
      # `Replication::Registry#fetch_all_doctype_definitions`.
      private def fetch_all_domains(db : DB::Connection) : Array({String, JSON::Any})
        rows = db.query_all(
          <<-SQL
            SELECT id, content FROM projections
            WHERE domain = 'core' AND doc_type = 'Domain' AND deleted_at IS NULL
              AND (content->>'draft' IS NULL OR content->>'draft' != 'true')
          SQL
        ) do |rs|
          {rs.read(String), rs.read(JSON::Any)}
        end
        rows
      end

      # Returns the distinct doctype names in a given source domain, from
      # published (non-draft) `core.DocType` projections. Used to expand a
      # domain-wide hook into per-doctype keys.
      private def fetch_doctypes_in_domain(db : DB::Connection, source_domain : String) : Array(String)
        db.query_all(
          <<-SQL,
            SELECT content->>'doctype' AS doctype FROM projections
            WHERE domain = 'core' AND doc_type = 'DocType' AND deleted_at IS NULL
              AND content->>'domain' = $1
              AND NOT EXISTS (
                SELECT 1 FROM projections dom
                WHERE dom.domain = 'core' AND dom.doc_type = 'Domain'
                  AND dom.id = $1
                  AND dom.deleted_at IS NULL
                  AND dom.content->>'draft' = 'true'
              )
          SQL
          source_domain,
          as: String
        )
      end

      private def default_domain_enabled : String -> Bool
        ->(domain : String) { Facet::Config.instance.domain_enabled?(domain) }
      end
    end
  end
end
