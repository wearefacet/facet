# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../config"
require "../util/cache_freshness"

module Facet
  module IAM
    # Process-local cache for `iam.Roles` projection content.
    #
    # Role content is read on every authenticated request (the `AuthHandler`
    # builders), on every credential-less request (the anonymous fallback),
    # on every static API-key request (`IAM::ApiKey.verify`), and on the
    # login / refresh / MCP / OAuth-consent / assistant-gate paths. All of
    # them read through `IAM::Helpers.find_role_content`, which delegates
    # here — the cache is transparent to every caller.
    #
    # Follows the invalidate-only contract shared with the doctype
    # definition cache, the OAuth origin cache, and the app-host cache:
    #
    # - `Event::Subscriber::RoleCache` listens on `fanout:iam.Roles:*` and
    #   evicts the mutated role's entry on every create / update / delete.
    # - Entries carry the monotonic stamp of their load and reload on reads
    #   past `cache.staleness_ttl_s` (`Util::CacheFreshness`) — the
    #   lost-fanout backstop that caps worst-case staleness. `0` disables
    #   the bound (fanout-only invalidation).
    #
    # Two implementations exist:
    # - `PassThrough` — the default. Every fetch loads from PostgreSQL. Used
    #   by CLI commands and by the spec suite (the test config sets the
    #   bound to `0`, and examples truncate the projections table, so a
    #   live process cache would serve wiped rows mid-suite).
    # - `ProcessCache` — mutex-guarded, installed by `main.cr` for the
    #   server command so Pub/Sub-driven evictions are visible across
    #   fibers.
    #
    # Cached values are shared read-only across fibers — callers must never
    # mutate the returned `JSON::Any`.
    module RoleStore
      # Abstract cache interface. Mirrors `Doctype::DefinitionCache`.
      module Cache
        abstract def fetch(qualified_id : String, & : -> JSON::Any?) : JSON::Any?
        abstract def clear : Nil
        abstract def clear_key(qualified_id : String) : Nil
      end

      # Loads on every fetch — no caching. The default for CLI commands and
      # the spec suite.
      class PassThrough
        include Cache

        def fetch(qualified_id : String, & : -> JSON::Any?) : JSON::Any?
          yield
        end

        def clear : Nil
        end

        def clear_key(qualified_id : String) : Nil
        end
      end

      # Process-wide cache. One stored entry: the role content plus the
      # monotonic stamp of the load — the stamp drives the staleness bound.
      # An absent role caches as a keyed miss (`@nil_keys`) with the same
      # bound, so a deleted role stops hitting the database on every read
      # while still reloading when the bound expires or the fanout lands.
      class ProcessCache
        include Cache

        private record Entry, content : JSON::Any, built_at : Time::Instant

        @store : Hash(String, Entry)
        @nil_keys : Hash(String, Time::Instant)
        @mutex : Mutex

        def initialize
          @store = {} of String => Entry
          @nil_keys = {} of String => Time::Instant
          @mutex = Mutex.new
        end

        def fetch(qualified_id : String, & : -> JSON::Any?) : JSON::Any?
          # Check (and load) under lock; only the loader within the lock
          # populates the store, so concurrent fetches never load twice.
          @mutex.synchronize do
            if entry = @store[qualified_id]?
              if Util::CacheFreshness.expired?(entry.built_at)
                # Past the staleness bound — reload as if evicted.
                @store.delete(qualified_id)
              else
                next entry.content
              end
            end

            if stamped = @nil_keys[qualified_id]?
              if Util::CacheFreshness.expired?(stamped)
                @nil_keys.delete(qualified_id)
              else
                next nil
              end
            end

            loaded = yield
            if loaded
              @store[qualified_id] = Entry.new(loaded, Time.instant)
            else
              @nil_keys[qualified_id] = Time.instant
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

        def clear_key(qualified_id : String) : Nil
          @mutex.synchronize do
            @store.delete(qualified_id)
            @nil_keys.delete(qualified_id)
          end
        end
      end

      class_getter cache : Cache { PassThrough.new }

      # Allows swapping the cache implementation (`main.cr` installs the
      # `ProcessCache` for the server command).
      def self.cache=(impl : Cache)
        @@cache = impl
      end

      # Fetches the raw `content` of one `iam.Roles` projection by its
      # qualified id (e.g. `iam.Roles.anonymous`) through the configured
      # cache. Returns `nil` when the role does not exist or is deleted.
      def self.fetch(db : DB::Connection, qualified_id : String) : JSON::Any?
        cache.fetch(qualified_id) { load_from_db(db, qualified_id) }
      end

      # Evicts one role's entry (content and keyed miss). Called by the
      # `Event::Subscriber::RoleCache` fanout subscriber on every
      # `iam.Roles` mutation.
      def self.invalidate(qualified_id : String) : Nil
        cache.clear_key(qualified_id)
      end

      # ── Private ──────────────────────────────────────────────────────

      private def self.load_from_db(db : DB::Connection, qualified_id : String) : JSON::Any?
        db.query_one?(
          "SELECT content FROM projections WHERE domain = 'iam' AND doc_type = 'Roles' AND id = $1 AND deleted_at IS NULL",
          qualified_id,
          as: JSON::Any,
        )
      end
    end
  end
end
