# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../util/cache_freshness"
require "./doctype_definition"
require "../mutation/client"
require "../error"

module Facet
  module Doctype
    # Abstract cache interface for doctype definitions.
    #
    # Two implementations exist:
    # - `RequestCache` — fiber-local per-request cache (active by default)
    # - `ProcessDefinitionCache` — long-lived process-wide cache with
    #   fanout-driven eviction plus a staleness bound (`main.cr` swaps it
    #   in for the server command)
    module DefinitionCache
      abstract def fetch(doctype_id : String, & : -> DoctypeDefinition?) : DoctypeDefinition?
      abstract def clear : Nil
      abstract def clear_key(doctype_id : String) : Nil
    end

    # Fiber-local per-request cache for doctype definitions.
    #
    # Lives only for the duration of a single request. Automatically
    # invalidated when the fiber finishes.
    class RequestDefinitionCache
      include DefinitionCache

      private def cache_store : Hash(String, JSON::Any)
        cache = Fiber.current.definition_cache
        if cache.nil?
          cache = {} of String => JSON::Any
          Fiber.current.definition_cache = cache
        end
        cache
      end

      def fetch(doctype_id : String, & : -> DoctypeDefinition?) : DoctypeDefinition?
        store = cache_store
        raw = store[doctype_id]?
        if raw
          parse_definition(raw)
        elsif store.has_key?(doctype_id)
          # Cached as nil (key present, value nil)
          nil
        else
          value = yield
          store[doctype_id] = value ? JSON.parse(value.to_json) : JSON::Any.new({} of String => JSON::Any)
          value
        end
      end

      def clear : Nil
        Fiber.current.definition_cache.try(&.clear)
      end

      def clear_key(doctype_id : String) : Nil
        Fiber.current.definition_cache.try(&.delete(doctype_id))
      end

      private def parse_definition(raw : JSON::Any) : DoctypeDefinition?
        Doctype::DoctypeDefinition.from_json(raw)
      rescue JSON::ParseException
        nil
      end
    end

    # Process-wide cache for doctype definitions.
    #
    # Lives for the lifetime of the process (not the request). Backed by a
    # mutex-guarded hash. Entries are evicted externally via `clear_key` —
    # typically by the `DoctypeCache` Pub/Sub subscriber listening to
    # `fanout:core.DocType:*` invalidation notices.
    #
    # A fanout can be lost (a mutation published while Redis was down), so
    # every entry also carries the monotonic stamp of its load and reloads
    # on reads past `cache.staleness_ttl_s` — see `Util::CacheFreshness`.
    # The bound caps worst-case staleness instead of letting a lost
    # eviction persist until restart.
    #
    # Used in production (see `main.cr`) so that doctype-definition evictions
    # issued from one request are visible to subsequent requests on other
    # fibers. The fiber-local `RequestDefinitionCache` still sits atop this
    # one within a single request to avoid re-locking for repeated fetches.
    class ProcessDefinitionCache
      include DefinitionCache

      # One stored entry: the raw JSON plus the monotonic stamp of the
      # load. The stamp drives the staleness bound; the raw JSON keeps the
      # value that `parse_definition` re-parses on every hit.
      private record Entry, raw : JSON::Any, built_at : Time::Instant

      @store : Hash(String, Entry)
      @nil_keys : Hash(String, Time::Instant)
      @mutex : Mutex

      def initialize
        @store = {} of String => Entry
        @nil_keys = {} of String => Time::Instant
        @mutex = Mutex.new
      end

      def fetch(doctype_id : String, & : -> DoctypeDefinition?) : DoctypeDefinition?
        # Check (and load) under lock; only the loader within the lock
        # populates the store, so concurrent fetches never load twice.
        @mutex.synchronize do
          if entry = @store[doctype_id]?
            if Util::CacheFreshness.expired?(entry.built_at)
              # Past the staleness bound — reload as if evicted.
              @store.delete(doctype_id)
            else
              next parse_definition(entry.raw)
            end
          end

          if stamped = @nil_keys[doctype_id]?
            if Util::CacheFreshness.expired?(stamped)
              @nil_keys.delete(doctype_id)
            else
              next nil
            end
          end

          loaded = yield
          if loaded
            @store[doctype_id] = Entry.new(JSON.parse(loaded.to_json), Time.instant)
          else
            @nil_keys[doctype_id] = Time.instant
          end
          loaded
        end
      end

      def clear : Nil
        @mutex.synchronize do
          @store.clear
          @nil_keys.clear
        end
      end

      def clear_key(doctype_id : String) : Nil
        @mutex.synchronize do
          @store.delete(doctype_id)
          @nil_keys.delete(doctype_id)
        end
      end

      private def parse_definition(raw : JSON::Any) : DoctypeDefinition?
        Doctype::DoctypeDefinition.from_json(raw)
      rescue JSON::ParseException
        nil
      end
    end

    # Central store for fetching doctype definitions from the projections table.
    #
    # All code that needs a `Doctype::DoctypeDefinition` should go through
    # this module instead of duplicating the SQL query.
    #
    # ## Caching
    #
    # The `fetch` method automatically uses a fiber-local request cache.
    # No caller changes needed — it's transparent.
    #
    # In production the process-wide `ProcessDefinitionCache` sits beneath
    # the request cache; its entries carry a staleness bound
    # (`cache.staleness_ttl_s`) so a lost Pub/Sub eviction can only delay
    # a refresh by that window.
    module DefinitionStore
      class_getter cache : DefinitionCache { RequestDefinitionCache.new }

      # Allows swapping the cache implementation (e.g. for Redis).
      def self.cache=(impl : DefinitionCache)
        @@cache = impl
      end

      # Fetches a parsed `DoctypeDefinition` by its qualified ID
      # (e.g. `"production.WorkOrder"`).
      #
      # Uses the configured cache transparently. In tests this is the
      # fiber-local `RequestDefinitionCache`; in production it is a
      # `ProcessDefinitionCache` so that Pub/Sub-driven evictions are visible
      # process-wide.
      # Returns `nil` if the doctype does not exist, is deleted, or the
      # stored definition is corrupt.
      def self.fetch(
        db : DB::Connection,
        doctype_id : String,
      ) : Doctype::DoctypeDefinition?
        cached = cache.fetch(doctype_id) { load_from_db(db, doctype_id) }
        cached
      end

      # Fetches a parsed `DoctypeDefinition` or produces a `ServiceError`.
      # For the singleton unknown-doctype path that every CRUD service
      # shares: an absent or corrupt definition becomes
      # `ServiceError(status, message)`.
      #
      # *message* defaults to `"Unknown doctype: #{doctype_id}"`.
      # Returns `DoctypeDefinition` on success, `Facet::ServiceError` when
      # the doctype does not exist, is deleted, or is corrupt.
      def self.fetch!(
        db : DB::Connection,
        doctype_id : String,
        message : String? = nil,
        status : Int32 = 404,
      ) : Doctype::DoctypeDefinition | Facet::ServiceError
        fetch(db, doctype_id) || Facet::ServiceError.new(status, message || "Unknown doctype: #{doctype_id}")
      end

      # Fetches a definition bypassing all caches (for doctype updates
      # that need to see the latest persisted state).
      def self.fetch_uncached(
        db : DB::Connection,
        doctype_id : String,
      ) : Doctype::DoctypeDefinition?
        load_from_db(db, doctype_id)
      end

      # Fetches the raw `content` and `meta` JSON values for a doctype
      # definition. Used by `Doctype::Update` for diff computation.
      #
      # Bypasses the cache since raw JSON is needed, not parsed.
      # Returns `nil` if the doctype does not exist or is deleted.
      def self.fetch_raw(
        db : DB::Connection,
        doctype_id : String,
      ) : {JSON::Any, JSON::Any}?
        row = db.query_one?(
          <<-SQL,
            SELECT content, meta FROM projections
            WHERE domain = 'core' AND doc_type = 'DocType' AND id = $1
            AND deleted_at IS NULL
          SQL
          doctype_id
        ) do |rs|
          {rs.read(JSON::Any), rs.read(JSON::Any)}
        end

        row
      end

      # Reads the projection `state` (the ULID of the last mutation) for a
      # doctype definition row. `Doctype::Update` returns it as the unchanged
      # re-save's `mutation_id` — the same ETag validator a write carries.
      # Returns `nil` if the doctype does not exist or is deleted.
      def self.fetch_state(
        db : DB::Connection,
        doctype_id : String,
      ) : String?
        db.query_one?(
          <<-SQL,
            SELECT state FROM projections
            WHERE domain = 'core' AND doc_type = 'DocType' AND id = $1
            AND deleted_at IS NULL
          SQL
          doctype_id, as: String
        )
      end

      # Invalidates a single doctype entry in the cache.
      # Called after a doctype update to ensure subsequent reads get the
      # new definition.
      def self.invalidate(doctype_id : String) : Nil
        cache.clear_key(doctype_id)
      end

      # ── Private ──────────────────────────────────────────────────────

      # Loads a doctype definition from the database.
      private def self.load_from_db(
        db : DB::Connection,
        doctype_id : String,
      ) : Doctype::DoctypeDefinition?
        row = db.query_one?(
          <<-SQL,
            SELECT content FROM projections
            WHERE domain = 'core' AND doc_type = 'DocType' AND id = $1
            AND deleted_at IS NULL
          SQL
          doctype_id
        ) do |rs|
          rs.read(JSON::Any)
        end

        return nil if row.nil?

        Doctype::DoctypeDefinition.from_json(row)
      rescue JSON::ParseException
        nil
      end
    end
  end
end
