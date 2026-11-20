# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "pg"
require "../config"
require "../../util/cache_freshness"

module Facet
  module IAM
    module OIDC
      # One enabled identity provider as the flow consumes it. Carries
      # everything the start route, the token exchange, and the identity
      # resolution need — **except the client secret**: that lives in the
      # sealed store (`iam.OIDCProvider.{doc_id}` / `client_secret`) and is
      # revealed once per token exchange, never cached and never carried.
      record Provider,
        name : String,
        label : String,
        issuer : String,
        client_id : String,
        doc_id : String,
        domains : Array(String),
        default_role : String?,
        auto_provision : Bool,
        scopes : Array(String)

      # Process-local cache for the enabled-provider list of
      # `iam.OIDCProvider`, in the `IAM::RoleStore` shape.
      #
      # The cache holds the **whole enabled-provider list under one key**
      # (not one entry per name): `summaries` needs the list and `find`
      # filters it in memory, and a single list entry avoids a name index
      # on `projections.content` that does not exist today.
      #
      # Follows the invalidate-only contract shared with the role store:
      #
      # - `Event::Subscriber::OidcProviderCache` listens on
      #   `fanout:iam.OIDCProvider:*` and clears the list on every
      #   create / update / delete (a provider flip takes effect on the
      #   next read).
      # - The single list entry carries the monotonic stamp of its load
      #   and reloads past `cache.staleness_ttl_s`
      #   (`Util::CacheFreshness`) — the lost-fanout backstop. `0`
      #   disables the bound.
      #
      # Two implementations exist:
      # - `PassThrough` — the default. Every read queries PostgreSQL. Used
      #   by CLI commands and by the spec suite (examples truncate the
      #   projections table, so a live process cache would serve wiped
      #   rows mid-suite).
      # - `ProcessCache` — mutex-guarded, installed by `main.cr` for the
      #   server command so Pub/Sub-driven evictions are visible across
      #   fibers.
      #
      # Cached records are shared read-only across fibers — callers must
      # never mutate the returned array.
      module ProviderStore
        # Abstract cache interface. Mirrors `IAM::RoleStore::Cache`.
        module Cache
          abstract def fetch(& : -> Array(Provider)?) : Array(Provider)?
          abstract def clear : Nil
        end

        # Loads on every read — no caching. The default for CLI commands
        # and the spec suite.
        class PassThrough
          include Cache

          def fetch(& : -> Array(Provider)?) : Array(Provider)?
            yield
          end

          def clear : Nil
          end
        end

        # Process-wide cache. One stored entry: the enabled-provider list
        # plus the monotonic stamp of the load — the stamp drives the
        # staleness bound. An empty list caches as a real (empty) entry, so
        # a zero-provider instance does not re-query on every read.
        class ProcessCache
          include Cache

          private record Entry, providers : Array(Provider), built_at : Time::Instant

          @entry : Entry?
          @mutex : Mutex

          def initialize
            @entry = nil
            @mutex = Mutex.new
          end

          def fetch(& : -> Array(Provider)?) : Array(Provider)?
            @mutex.synchronize do
              if entry = @entry
                if Util::CacheFreshness.expired?(entry.built_at)
                  # Past the staleness bound — reload as if evicted.
                  @entry = nil
                else
                  return entry.providers
                end
              end

              loaded = yield || [] of Provider
              @entry = Entry.new(loaded, Time.instant)
              loaded
            end
          end

          def clear : Nil
            @mutex.synchronize do
              @entry = nil
            end
          end
        end

        class_getter cache : Cache { PassThrough.new }

        # Allows swapping the cache implementation (`main.cr` installs the
        # `ProcessCache` for the server command).
        def self.cache=(impl : Cache)
          @@cache = impl
        end

        # Loads the enabled providers (tombstones excluded), through the
        # configured cache. A provider document without a usable name or
        # issuer is skipped — the registry serves only well-formed
        # entries; the Lua hooks make malformed documents unreachable
        # through the pipeline anyway.
        def self.load(db : DB::Connection) : Array(Provider)
          cache.fetch { load_from_db(db) }
        end

        # Evicts the cached list. Called by the
        # `Event::Subscriber::OidcProviderCache` fanout subscriber on
        # every `iam.OIDCProvider` mutation.
        def self.invalidate : Nil
          cache.clear
        end

        # ── Private ──────────────────────────────────────────────────

        private def self.load_from_db(db : DB::Connection) : Array(Provider)
          rows = db.query_all(
            <<-SQL,
              SELECT id, content
              FROM projections
              WHERE domain = 'iam' AND doc_type = 'OIDCProvider' AND deleted_at IS NULL
                AND COALESCE((content->>'enabled')::boolean, true)
            SQL
            as: {String, JSON::Any},
          )

          rows.compact_map do |doc_id, content|
            name = content["name"]?.try(&.as_s?)
            issuer = content["issuer"]?.try(&.as_s?)
            client_id = content["client_id"]?.try(&.as_s?)
            next nil if name.nil? || name.empty? || issuer.nil? || issuer.empty? || client_id.nil?

            domains_raw = content["domains"]?.try(&.as_a?)
            domains = (domains_raw || [] of JSON::Any).compact_map(&.as_s?).map(&.downcase)
            scopes_raw = content["scopes"]?.try(&.as_a?)
            scopes = scopes_raw ? scopes_raw.compact_map(&.as_s?) : ["openid", "email", "profile"]
            Provider.new(
              name: name,
              label: content["label"]?.try(&.as_s?) || name,
              issuer: issuer,
              client_id: client_id,
              doc_id: doc_id,
              domains: domains,
              default_role: content["default_role"]?.try(&.as_s?),
              auto_provision: content["auto_provision"]?.try(&.as_bool?) || false,
              scopes: scopes,
            )
          end
        end
      end
    end
  end
end
