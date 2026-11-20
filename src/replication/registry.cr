# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "json"
require "pg"
require "../database"
require "../util/cache_freshness"
require "../doctype/doctype_definition"
require "../doctype/definition_store"
require "../grants"
require "./binding"
require "./validator"

module Facet
  module Replication
    # Static map of replication edges, keyed by **source doctype**.
    #
    # Built once at startup, then kept in sync with `core.DocType` mutations
    # via a **stale-flag / lazy-rebuild** model: the `DoctypeCache` Pub/Sub
    # subscriber marks the registry stale on every `core.DocType` fanout event,
    # and the next read (`bindings_for`, `source_doctypes`, `consumer_domains`)
    # rebuilds from the DB on demand. This mirrors `DefinitionStore`'s
    # invalidate-only pattern — events never rebuild, they only signal
    # staleness; each node recovers via its own direct DB query and re-caches.
    # The stale flag coalesces a flock of events spaced milliseconds apart
    # (e.g. publishing a whole domain) into a single rebuild on the next read.
    #
    # A fanout can be lost (a mutation published while Redis was down), so the
    # registry also stamps the monotonic time of its last successful build and
    # rebuilds on reads past `cache.staleness_ttl_s` — see
    # `Util::CacheFreshness`. The bound caps worst-case staleness instead of
    # letting it persist until restart.
    #
    # The registry is the single source of truth for:
    #
    # - which source doctypes this instance must subscribe to,
    # - which consuming domains own a stream subscriber,
    # - which `(consumer, ref_field, replica_field)` edges exist for a source.
    #
    # ## Fail-closed build-time re-checks
    #
    # Every binding is re-checked at build time. The source field is
    # resolved for every edge — same-domain edges included. A binding
    # whose source field does not resolve is dropped, and a binding whose
    # source field is a `secret` is dropped: a copy would place the
    # secret's marker object into the public replica field. The authoring
    # gate skips a source it cannot resolve, so a consumer registered
    # before its producer would otherwise bind the edge unchecked once
    # the producer lands (B-164). A cross-domain binding survives only
    # when an active `core.DomainGrant` covers the source field's tags
    # (untagged fields resolve to `["default"]`). If coverage is missing —
    # no grant, an inactive ticket, or a tag not in the resource entry —
    # the binding is **dropped** and the miss is logged. The doctype-level
    # `Replication::Validator` is the authoritative gate at doctype
    # create/update time; the registry is the runtime safety net.
    #
    # ## Active-domain filter
    #
    # Only consuming domains that are enabled per `Config#domain_enabled?`
    # (passed in as a predicate for testability) get their bindings included.
    # Source-domain enablement is irrelevant — replication consumes from
    # source streams regardless of whether this instance serves the source
    # domain's HTTP routes.
    class Registry
      Log = ::Log.for("facet.replication.registry")

      @bindings : Hash(String, Array(Binding))
      @mutex : Mutex
      @stale : Bool
      @built_at : Time::Instant?

      def initialize(@domain_enabled : String -> Bool = default_domain_enabled)
        @bindings = {} of String => Array(Binding)
        @mutex = Mutex.new
        @stale = true
        @built_at = nil
      end

      # Marks the registry as stale without rebuilding. Called by the
      # `DoctypeCache` Pub/Sub subscriber on every `core.DocType` fanout event.
      # The next read triggers a lazy rebuild from the DB. No-op to call in a
      # flock — the flag is idempotent (set-true), so N events produce exactly
      # one rebuild on the next read.
      def mark_stale : Nil
        @mutex.synchronize { @stale = true }
      end

      # Rebuilds the binding map from all non-deleted `core.DocType`
      # projections whose domain is **not** a draft. Draft domains are
      # excluded both as consumers (this filter) and as producers (no
      # draft consumer ever registers a binding, so a draft doctype never
      # appears in `source_doctypes`). This is the structural runtime cut
      # for draft isolation: draft doctypes never appear as replication
      # sources or consumers, so nothing downstream in the registry ever
      # sees them.
      #
      # An `EXISTS` subquery against the `core.Domain` projection row's
      # `draft` flag is the single filter point. The `_` cosmetic prefix
      # on draft domain names is **never** keyed off — `draft = true` is
      # the authoritative signal.
      def build(db : DB::Connection) : Nil
        rebuilt = {} of String => Array(Binding)

        definitions = fetch_all_doctype_definitions(db)

        definitions.each do |consumer_def|
          next unless @domain_enabled.call(consumer_def.domain)

          consumer_def.fields.each do |field_name, field_def|
            rep_config = field_def.replicate
            next if rep_config.nil?

            build_binding(db, consumer_def, field_name, field_def, rep_config, rebuilt)
          end
        end

        @mutex.synchronize { @bindings = rebuilt; @stale = false; @built_at = Time.instant }

        Log.info do
          total = rebuilt.values.sum(&.size)
          "Replication registry rebuilt: #{total} binding(s) across " \
          "#{rebuilt.size} source doctype(s)"
        end
      end

      # Returns all bindings whose source is `source_doctype` (qualified id,
      # e.g. `"identity.Person"`). Empty array if this source has no consumers.
      # Triggers a lazy rebuild from the DB if the registry has been marked
      # stale since the last build.
      def bindings_for(source_doctype : String) : Array(Binding)
        ensure_fresh
        @mutex.synchronize { @bindings.fetch(source_doctype, [] of Binding).dup }
      end

      # Distinct source doctypes that this instance must subscribe to.
      # Triggers a lazy rebuild from the DB if the registry is stale.
      def source_doctypes : Set(String)
        ensure_fresh
        @mutex.synchronize do
          set = Set(String).new
          @bindings.each_key { |k| set << k }
          set
        end
      end

      # Distinct consuming domains that own a stream subscriber.
      # Triggers a lazy rebuild from the DB if the registry is stale.
      def consumer_domains : Set(String)
        ensure_fresh
        @mutex.synchronize do
          set = Set(String).new
          @bindings.each_value do |bindings|
            bindings.each { |b| set << b.consumer_domain }
          end
          set
        end
      end

      # ── Stale-flag / lazy-rebuild ──────────────────────────────────────

      # Rebuilds the registry from the DB if it has been marked stale since
      # the last build, or if the last successful build is older than the
      # staleness bound (`Util::CacheFreshness`) — the safety net for a lost
      # fanout. Called transparently by every public reader so callers
      # never observe stale data without opting into the rebuild cost.
      #
      # Uses `Database.with_db(:read_only)`: a rebuild only reads. On a read
      # entry point this reuses the caller's ro pin; on a write entry point
      # it reuses the rw pin (the pin-reuse contract), so no write path pays
      # a second checkout. Checks out a fresh ro connection otherwise (e.g.
      # the stream subscriber's polling fiber). A failed rebuild is logged
      # and the cached state is served — `@stale` stays `true` so the next
      # read retries.
      private def ensure_fresh : Nil
        needs_rebuild = @mutex.synchronize { @stale || Util::CacheFreshness.expired?(@built_at) }
        return unless needs_rebuild
        Database.with_db(:read_only) { |db| build(db) }
      rescue ex : Exception
        Log.warn { "Lazy registry rebuild failed (serving cached state): #{ex.message}" }
      end

      # ── Private ──────────────────────────────────────────────────────

      private def fetch_all_doctype_definitions(db : DB::Connection) : Array(Doctype::DoctypeDefinition)
        rows = db.query_all(
          <<-SQL,
            SELECT d.content FROM projections d
            WHERE d.domain = 'core' AND d.doc_type = 'DocType' AND d.deleted_at IS NULL
              AND NOT EXISTS (
                SELECT 1 FROM projections dom
                WHERE dom.domain = 'core' AND dom.doc_type = 'Domain'
                  AND dom.id = d.content->>'domain'
                  AND dom.deleted_at IS NULL
                  AND dom.content->>'draft' = 'true'
              )
          SQL
          as: JSON::Any
        )

        definitions = [] of Doctype::DoctypeDefinition
        rows.each do |row|
          begin
            definitions << Doctype::DoctypeDefinition.from_json(row)
          rescue ex : JSON::ParseException
            Log.warn { "Skipping corrupt core.DocType projection: #{ex.message}" }
          end
        end
        definitions
      end

      # Resolves a single replicate field into a `Binding` (or skips it).
      private def build_binding(
        db : DB::Connection,
        consumer_def : Doctype::DoctypeDefinition,
        field_name : String,
        field_def : Doctype::FieldDefinition,
        rep_config : Doctype::ReplicateConfig,
        rebuilt : Hash(String, Array(Binding)),
      ) : Nil
        # 1. Resolve `via` → source doctype
        via_field = consumer_def.fields[rep_config.via]?
        if via_field.nil?
          Log.warn do
            "Replicate field '#{consumer_def.qualified_name}.#{field_name}': " \
            "'via' field '#{rep_config.via}' not found — skipping binding"
          end
          return
        end

        source_doctype = via_field.qualified_doctype
        if source_doctype.nil?
          Log.warn do
            "Replicate field '#{consumer_def.qualified_name}.#{field_name}': " \
            "'via' field '#{rep_config.via}' has no target doctype — skipping binding"
          end
          return
        end

        # 2. Resolve the source field definition (cached store). Same-domain
        #    edges resolve it too: the authoring-time invariants can be
        #    defeated by ordering — a consumer registered while its source
        #    doctype does not exist yet is never re-checked when the
        #    producer lands (B-164) — so the registry re-asserts the field
        #    rules on every rebuild.
        source_domain = source_doctype.split('.', 2)[0]?
        if source_domain.nil?
          Log.warn { "Replicate binding: malformed source doctype '#{source_doctype}' — skipping" }
          return
        end

        source_defn = Doctype::DefinitionStore.fetch(db, source_doctype)
        source_field_def = source_defn.try(&.fields[rep_config.field]?)
        if source_field_def.nil?
          Log.warn do
            "Replicate binding '#{consumer_def.qualified_name}.#{field_name}': " \
            "source field '#{source_doctype}.#{rep_config.field}' not found — fail-closed skip"
          end
          return
        end

        # 3. A secret source field is never bound. A copy would place the
        #    secret's marker object into the public replica field.
        if source_field_def.type.try(&.type_name) == "secret"
          Log.warn do
            "Replicate binding '#{consumer_def.qualified_name}.#{field_name}': " \
            "source field '#{source_doctype}.#{rep_config.field}' is a secret — dropping binding"
          end
          return
        end

        # 4. Re-assert the producer-side grant (fail-closed). Coverage is
        #    tag-grain: the source field's tags (untagged → ["default"]) must
        #    share at least one name with the granted tags of the producer
        #    doctype's resource entry on an active grant.
        if source_domain != consumer_def.domain
          source_doctype_unqualified = source_doctype.split('.', 2)[1]? || source_doctype
          field_tags = source_field_def.tags || [Grants::DEFAULT_TAG]

          covered = Grants::Registry.covers?(db, consumer_def.domain, source_domain, source_doctype_unqualified, field_tags)
          unless covered
            Log.warn do
              "Replicate binding '#{consumer_def.qualified_name}.#{field_name}': " \
              "no active grant from '#{source_domain}' to '#{consumer_def.domain}' covering " \
              "'#{source_doctype}.#{rep_config.field}' (tags: #{field_tags.join(", ")}) — fail-closed skip"
            end
            return
          end
        end

        binding = Binding.new(
          consumer_domain: consumer_def.domain,
          consumer_doctype: consumer_def.doctype,
          ref_field: rep_config.via,
          replica_field: field_name,
          source_doctype: source_doctype,
          source_field: rep_config.field,
          on_source_delete: field_def.on_source_delete,
        )

        (rebuilt[source_doctype] ||= [] of Binding) << binding
        nil
      end

      private def default_domain_enabled : String -> Bool
        ->(domain : String) { Facet::Config.instance.domain_enabled?(domain) }
      end
    end
  end
end
