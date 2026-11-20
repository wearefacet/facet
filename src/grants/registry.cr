# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "json"
require "pg"
require "../database"
require "../doctype/definition_store"
require "../util/cache_freshness"

module Facet
  module Grants
    # Process-wide grant coverage cache, keyed by
    # `(consumer, producer, doctype)`.
    #
    # Built from non-deleted `core.DomainGrant` projections. Both sides
    # must be live: the parent (producer) domain must pass the
    # `domain_enabled?` predicate and carry `draft != true` on its
    # `core.Domain` row, and the `consumer_domain` target must be a live
    # domain — a draft on either side excludes the grant (draft isolation,
    # the `Hooks::Registry` rule). The `active` flag on the document is the
    # acceptance state: an inactive grant builds no entry.
    #
    # Follows the invalidate-only contract of the currency registry and the
    # hooks registry:
    #
    # - The `DoctypeCache` Pub/Sub subscriber marks the registry stale on
    #   every `fanout:core.DomainGrant:*` fanout (create, update, delete).
    # - The next read rebuilds from the `projections` table. Rebuilds are
    #   replace-all so deactivations, deletes, and resource edits land.
    # - There is no DB access on the invalidation path itself.
    #
    # A lost fanout is bounded by `cache.staleness_ttl_s`
    # (`Util::CacheFreshness`). Field tags resolve through
    # `Doctype::DefinitionStore`, which the existing `core.DocType` fanout
    # already invalidates — a producer tag change re-asserts coverage on
    # the next rebuild (adding a tag restores bindings; removing one cuts
    # them, D8 governs already-copied values).
    module Registry
      Log = ::Log.for("facet.grants.registry")

      # One active grant's resource mask, keyed by producer doctype name.
      private record Entry,
        producer : String,
        consumer : String,
        resources : Hash(String, Array(String))

      @@entries : Hash(String, Array(Entry)) = {} of String => Array(Entry)
      @@stale = true
      @@refreshed_at : Time::Instant? = nil

      def self.stale? : Bool
        @@stale
      end

      # Pure flag — called by the Pub/Sub subscriber. No DB access.
      def self.mark_stale : Nil
        @@stale = true
      end

      # Marks the registry fresh without a rebuild. Spec plumbing: tests
      # seed grant rows and rebuild explicitly.
      def self.mark_fresh : Nil
        @@stale = false
        @@refreshed_at = Time.instant
      end

      # True when an active grant from `producer` to `consumer` names
      # `doctype` with a tag set that shares at least one name with
      # `field_tags`. Untagged producer fields resolve to `["default"]`
      # before the call (the callers pass the effective tag set).
      def self.covers?(
        db : DB::Connection,
        consumer : String,
        producer : String,
        doctype : String,
        field_tags : Array(String),
      ) : Bool
        ensure_fresh(db)
        entries_for(consumer, producer).any? do |entry|
          granted = entry.resources[doctype]?
          next false if granted.nil?
          field_tags.any? { |t| granted.includes?(t) }
        end
      end

      # True when an active grant from `producer` to `consumer` names
      # `doctype` at all (any tags) — used to admit hook fires.
      def self.active?(
        db : DB::Connection,
        consumer : String,
        producer : String,
        doctype : String,
      ) : Bool
        ensure_fresh(db)
        entries_for(consumer, producer).any?(&.resources.has_key?(doctype))
      end

      # Reduces `content` to the fields whose tags share at least one name
      # with the granted tags of the (consumer, producer, doctype) grant.
      # Used by hook delivery and Lua cross-domain reads. Same-domain
      # callers never route through here (the gates skip first).
      def self.project(
        db : DB::Connection,
        consumer : String,
        producer : String,
        doctype : String,
        content : JSON::Any,
      ) : JSON::Any
        ensure_fresh(db)
        granted_any = entries_for(consumer, producer).any?(&.resources.has_key?(doctype))
        return content unless granted_any

        qualified = "#{producer}.#{doctype}"
        defn = Doctype::DefinitionStore.fetch(db, qualified)
        return JSON::Any.new(Hash(String, JSON::Any).new) if defn.nil?

        effective_tags = granted_tags(db, consumer, producer, doctype)
        projected = Hash(String, JSON::Any).new
        content.as_h?.try do |h|
          h.each do |field_name, value|
            field = defn.fields[field_name]?
            next if field.nil? # keep nothing for undeclared keys
            tags = field.tags || [DEFAULT_TAG]
            next unless tags.any? { |t| effective_tags.includes?(t) }
            projected[field_name] = value
          end
        end
        JSON::Any.new(projected)
      end

      # ── Internals ─────────────────────────────────────────────────────

      private def self.entries_for(consumer : String, producer : String) : Array(Entry)
        @@entries.fetch(key(consumer, producer), [] of Entry)
      end

      private def self.key(consumer : String, producer : String) : String
        "#{consumer}\u{1}#{producer}"
      end

      # Union of the granted tag sets across every active grant entry for
      # the doctype (a consumer may hold several grants from one producer).
      private def self.granted_tags(
        db : DB::Connection,
        consumer : String,
        producer : String,
        doctype : String,
      ) : Array(String)
        tags = Set(String).new
        entries_for(consumer, producer).each do |entry|
          granted = entry.resources[doctype]?
          granted.try { |g| g.each { |t| tags << t } }
        end
        tags.to_a
      end

      # Rebuilds the registry when stale, or past the staleness bound —
      # the safety net for a lost fanout.
      private def self.ensure_fresh(db : DB::Connection) : Nil
        refresh(db) if @@stale || Util::CacheFreshness.expired?(@@refreshed_at)
      end

      # Rebuilds from every non-deleted `core.DomainGrant` projection.
      # Replace-all by design. Grants whose producer or consumer domain is
      # a draft (or whose producer fails `domain_enabled?`) are skipped.
      def self.refresh(db : DB::Connection) : Nil
        rows = db.query_all(
          <<-SQL
            SELECT g.id,
                   g.meta->>'parent_id' AS parent_id,
                   g.content->>'consumer_domain' AS consumer_id,
                   g.content->'resources' AS resources,
                   g.content->>'active' AS active
            FROM projections g
            WHERE g.domain = 'core' AND g.doc_type = 'DomainGrant' AND g.deleted_at IS NULL
          SQL
        ) { |rs| {rs.read(String), rs.read(String?), rs.read(String?), rs.read(JSON::Any?), rs.read(String?)} }

        live_domains = fetch_live_domains(db)

        rebuilt = {} of String => Array(Entry)
        rows.each do |grant_id, parent_id, consumer_id, resources_raw, active|
          # Reference values and the parent link both store the fully
          # qualified `{domain}.{Doctype}.{id}` form. The domain name IS
          # the `core.Domain` document id, so stripping the
          # `core.Domain.` prefix yields it. Split only on the first two
          # dots — ids may contain dots.
          strip = ->(v : String) do
            v.starts_with?("core.Domain.") ? v["core.Domain.".size..] : v
          end
          producer = parent_id.try { |p| strip.call(p).split('.', 2)[0]? }
          consumer = consumer_id.try { |c| strip.call(c).split('.', 2)[0]? }

          # Draft isolation + liveness: both sides must be live domains.
          # A domain row that does not exist (or is deleted/draft) fails the
          # check — the grant is inert until both sides are live. The
          # `active` flag is the acceptance state — an inactive ticket
          # builds no entry.
          next if producer.nil? || consumer.nil?
          next unless live_domains[producer]? == true && live_domains[consumer]? == true
          next unless Facet::Config.instance.domain_enabled?(producer)
          next unless active == "true"

          resources = Grants::Validator.parse_resources(resources_raw)
          next if resources.nil?

          mask = resources.to_h do |entry|
            {entry.doctype, entry.tags}
          end
          (rebuilt[key(consumer, producer)] ||= [] of Entry) << Entry.new(
            producer: producer,
            consumer: consumer,
            resources: mask,
          )
          Log.debug { "Grants registry: loaded grant #{grant_id} (#{producer} → #{consumer})" }
        end

        @@entries = rebuilt
        @@stale = false
        @@refreshed_at = Time.instant
        count = rebuilt.values.sum(&.size)
        Log.info { "Grants registry rebuilt: #{count} active grant(s)" }
      end

      # Liveness map over `core.Domain` projections: a domain id is `true`
      # when it exists, is not deleted, and carries `draft != true`.
      private def self.fetch_live_domains(db : DB::Connection) : Hash(String, Bool)
        rows = db.query_all(
          <<-SQL
            SELECT id FROM projections
            WHERE domain = 'core' AND doc_type = 'Domain' AND deleted_at IS NULL
              AND (content->>'draft' IS NULL OR content->>'draft' != 'true')
          SQL
        ) { |rs| rs.read(String) }
        map = {} of String => Bool
        rows.each { |id| map[id] = true }
        map
      end
    end
  end
end
