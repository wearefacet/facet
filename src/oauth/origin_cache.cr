# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "log"
require "json"
require "redis"
require "../database"

module Facet
  module OAuth
    # Process-wide cache of `allowed_origins → app_id` mappings.
    #
    # The CORS handler (`OAuth::Cors`) consults this cache to decide whether
    # an `Origin` header on a request to `/OAuth/token` or `/Api/*` is
    # registered. Without this cache the CORS handler would re-query the
    # `app.App` projections on **every** API request — an unacceptable cost.
    #
    # ## Invalidation
    #
    # `Event::Subscriber::AppCache` mirrors `DoctypeCache`: a process-wide
    # Redis Pub/Sub listener on `fanout:app.App:*` calls `mark_stale` here.
    # The next `origin_allowed?` call rebuilds the cache lazily from the DB.
    # This **invalidate-only** pattern mirrors `Doctype::DefinitionStore` /
    # `Replication::Manager` — never eager rebuild, always lazy on read.
    #
    # A fanout can be lost (a mutation published while Redis was down), so
    # the cache also carries the monotonic stamp of its last rebuild and
    # treats reads past `cache.staleness_ttl_s` as stale — see
    # `Util::CacheFreshness`. The bound caps worst-case staleness instead
    # of letting it persist until restart.
    #
    # ## Thread safety
    #
    # Concurrent fibers may read and rebuild simultaneously. The cache uses
    # a `Mutex` to make the read path atomic; rebuilds may be duplicated
    # under contention, which is safe (idempotent DB reads, same values).
    class OriginCache
      Log = ::Log.for("facet.oauth.origin_cache")

      # One immutable snapshot: the rebuilt mapping plus the monotonic stamp
      # of the rebuild. Holding both in one reference keeps the lock-free
      # fast path race-free — a single reference read carries the data and
      # its age, with no second unlocked read to tear.
      private record Entry, data : Hash(String, String), built_at : Time::Instant

      @@entry : Entry? = nil
      @@mutex = Mutex.new

      # Returns true when the given origin (scheme://host[:port]) is
      # registered as an `allowed_origins` entry on at least one `app.App`
      # projection. The matching app's id is exposed via `app_for_origin`
      # for callers that need it (e.g. `/OAuth/token` to narrow CORS
      # by the request's `client_id`).
      def self.origin_allowed?(origin : String) : Bool
        !entry.data[origin]?.nil?
      end

      # Returns the app_id bound to this origin, or nil if the origin is not
      # registered. O(1) hash lookup.
      def self.app_for_origin(origin : String) : String?
        entry.data[origin]?
      end

      # Marks the cache stale so the next read rebuilds from the DB.
      # Called by the `Event::Subscriber::AppCache` Pub/Sub listener on
      # every `app.App` mutation event.
      def self.mark_stale : Nil
        @@mutex.synchronize { @@entry = nil }
        Log.debug { "Origin cache marked stale" }
      end

      # Forces a rebuild on the next read. Alias for `mark_stale`, used by
      # specs that mutate `app.App` rows directly without going through the
      # event system.
      def self.reset : Nil
        mark_stale
      end

      # ── Internals ──────────────────────────────────────────────────

      # Returns the current entry, rebuilding when it is absent or past
      # the staleness bound. The warm path is lock-free: one reference
      # read plus the freshness check. Rebuilds happen under the mutex and
      # may be duplicated under contention, which is safe (idempotent DB
      # reads, same values).
      private def self.entry : Entry
        current = @@entry
        return current if current && !Util::CacheFreshness.expired?(current.built_at)
        @@mutex.synchronize do
          current = @@entry
          next current if current && !Util::CacheFreshness.expired?(current.built_at)
          fresh = Entry.new(rebuild, Time.instant)
          @@entry = fresh
          fresh
        end
      end

      # Rebuilds the cache from the live `app.App` projections. Includes
      # only `status = 'active'` apps — a disabled app's origins no longer
      # receive CORS permission, which mirrors the AuthHandler's gating on
      # `active` status for token verification.
      private def self.rebuild : Hash(String, String)
        rebuilt = {} of String => String
        Database.with_db(:read_only) do |db|
          db.query(
            <<-SQL
              SELECT id, content->'allowed_origins'
              FROM projections
              WHERE domain = 'app' AND doc_type = 'App'
                AND content->>'status' = 'active'
                AND deleted_at IS NULL
            SQL
          ) do |rs|
            rs.each do
              id = rs.read(String)
              origins_raw = rs.read(JSON::Any?)
              next if origins_raw.nil?
              next unless origins_raw.as_a?
              origins_raw.as_a.each do |o|
                if s = o.as_s?
                  rebuilt[s] = id
                end
              end
            end
          end
        end
        Log.debug { "Origin cache rebuilt (#{rebuilt.size} origins)" }
        rebuilt
      rescue ex : Exception
        Log.error { "Origin cache rebuild failed: #{ex.message}; serving empty cache" }
        {} of String => String
      end
    end
  end
end
