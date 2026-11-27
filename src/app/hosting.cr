# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "kemal"
require "json"
require "log"
require "uri"
require "../config"
require "../database"
require "../artifact/store"
require "../artifact/uploader"
require "../util/script_helpers"

module Facet
  module App
    # Host-based dispatch of app deployments.
    #
    # A published build is served from the app's own host: each `app.App`
    # document carries an optional `host` (e.g. `hr.app.company.tld`) and an
    # `active_deployment` reference; the wildcard DNS record and wildcard
    # certificate cover every future hostname under the suffix, and this
    # handler resolves hosts from live document state — a new app goes live
    # without a Facet restart or a config change.
    #
    # ## Dispatch order (fixed)
    #
    # 1. Facet's own hosts win. If the request hostname equals the
    #    configured `host`, `base_url`, or `artifact_base_url` host, the
    #    request falls through to the main router untouched — before any
    #    app lookup. An app that illegally claims Facet's own host cannot
    #    receive traffic even if such a document existed (the Lua hook's
    #    reserved-host check is the front-line error surface; this is the
    #    defence-in-depth backstop).
    # 2. Exact-match host lookup. The hostname (lowercased, port stripped)
    #    is matched against the `host` field of `app.App` — a literal string
    #    compare, never a suffix match. Miss → bare 404, no detail: requests
    #    with arbitrary Host headers (direct IP access, other vhosts on the
    #    same box) never reach a document query result. The one exception
    #    is the habitual `Host: localhost` miss — the body names the
    #    configured host and the loopback literal form instead.
    # 3. Resolve app → `active_deployment` → files map, gate `status ==
    #    "active"`, and stream the mapped artifact.
    #
    # ## Deliberately not the grant layer
    #
    # A published build is public by definition; the app pointer *is* the
    # authorization. Owner rows are still written at upload time (provenance
    # and audit), but serving never walks ACLs — that keeps the hot path to
    # two indexed reads (app by host, deployment by id) plus one store read.
    module Hosting
      Log = ::Log.for("facet.app.hosting")

      # Conservative v1 cache policy for content-addressed-looking assets
      # (open question 5 of the plan): a short shared max-age, no `immutable`
      # — "path contains a content hash" is not a contract the deploy surface
      # enforces.
      CACHE_CONTROL = "public, max-age=300"

      # The app shell (`index.html` — the root document and every
      # navigation fallback hit) is served with `no-cache`: browsers
      # may store it but must revalidate before reuse. There is no
      # validator (no ETag /
      # Last-Modified on artifacts), so revalidation is a full refetch — the
      # shell is small and this is what makes a deploy visible on the next
      # navigation instead of up to `CACHE_CONTROL`'s max-age later. Stale
      # shell + fresh assets is the worst state: the browser would run old
      # bootstrap code that no longer matches the deployed asset names.
      SHELL_CACHE_CONTROL = "public, no-cache"

      # The SPA shell fallback answers page loads only. Fetch Metadata
      # marks a top-level navigation `Sec-Fetch-Mode: navigate` and an
      # iframe navigation `nested-navigate`; every asset fetch (scripts,
      # styles, images, `fetch()`) sends another mode. An asset fetch
      # that misses the files map must get a bare 404 — 200 HTML under
      # an asset URL fails as a MIME error instead of a missing file.
      NAVIGATION_MODES = %w[navigate nested-navigate]

      # ── Host cache ─────────────────────────────────────────────────────

      # Process-wide `host → app_id` cache, mirroring `OAuth::OriginCache`:
      # invalidate-only, lazy rebuild on the next read. `mark_stale` is
      # called by `Event::Subscriber::AppCache` on every `app.App` mutation,
      # so an app can set or change its host without a restart. Includes
      # only live, `status = "active"` apps that carry a `host` value — an
      # app without a host is simply never dispatched. A lost fanout (a
      # mutation published while Redis was down) is bounded by
      # `cache.staleness_ttl_s` — see `Util::CacheFreshness`.
      module HostCache
        # One immutable snapshot: the rebuilt mapping plus the monotonic
        # stamp of the rebuild. One reference read carries the data and its
        # age, so the lock-free fast path never tears.
        private record Entry, data : Hash(String, String), built_at : Time::Instant

        @@entry : Entry? = nil
        @@mutex = Mutex.new

        # Returns the app id bound to this (lowercase, port-less) hostname,
        # or nil when no active app claims it.
        def self.app_for_host(host : String) : String?
          entry.data[host]?
        end

        # Marks the cache stale so the next read rebuilds from the DB.
        def self.mark_stale : Nil
          @@mutex.synchronize { @@entry = nil }
          Log.debug { "App host cache marked stale" }
        end

        # Forces a rebuild on the next read. Alias for `mark_stale`, used by
        # specs that mutate `app.App` rows without a running event fanout.
        def self.reset : Nil
          mark_stale
        end

        # Returns the current entry, rebuilding when it is absent or past
        # the staleness bound. The warm path is lock-free; rebuilds happen
        # under the mutex and may be duplicated under contention, which is
        # safe (idempotent DB reads, same values).
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

        private def self.rebuild : Hash(String, String)
          rebuilt = {} of String => String
          Database.with_db(:read_only) do |db|
            db.query(
              <<-SQL
                SELECT id, lower(content->>'host')
                FROM projections
                WHERE domain = 'app' AND doc_type = 'App'
                  AND content->>'status' = 'active'
                  AND content->>'host' IS NOT NULL
                  AND deleted_at IS NULL
              SQL
            ) do |rs|
              rs.each do
                id = rs.read(String)
                host = rs.read(String?)
                next if host.nil? || host.empty?
                rebuilt[host] = id
              end
            end
          end
          Log.debug { "App host cache rebuilt (#{rebuilt.size} hosts)" }
          rebuilt
        rescue ex : Exception
          Log.error { "App host cache rebuild failed: #{ex.message}; serving empty cache" }
          {} of String => String
        end
      end

      # True when `hostname` (lowercase, port-less) is one of Facet's own
      # hosts — the dispatcher must fall through before any app lookup.
      def self.facet_host?(hostname : String) : Bool
        Util::ScriptHelpers.facet_hosts.includes?(hostname)
      end

      # ── Kemal handler ──────────────────────────────────────────────────

      # Registered **before** the main router (see `HTTP::Server.routes`).
      # Facet's own hosts fall through; a registered app host is served
      # here; everything else gets a 404 whose `hint` names the rejected
      # Host and the configured set (`localhost` keeps its own routing
      # hint that names a working URL).
      class Handler < Kemal::Handler
        def call(env)
          hostname = env.request.hostname.try(&.downcase)

          # No Host header (HTTP/1.0 client) or Facet's own host — the main
          # router owns the request.
          return call_next(env) if hostname.nil? || Hosting.facet_host?(hostname)

          app_id = HostCache.app_for_host(hostname)
          return unknown_host(env, hostname) unless app_id

          Hosting.serve(env, app_id)
        rescue ex : Exception
          Log.error { "App hosting dispatch failed: #{ex.message}" }
          env.response.status_code = 500
          env.response.content_type = "application/json"
          Facet::HTTP::Helpers.no_store(env)
          env.response.print({error: "Internal server error"}.to_json)
        end

        # The routing hint for the habitual `Host: localhost` miss, or nil.
        # Only `localhost` gets one: the configured host's own bare name is
        # already a facet host and falls through, and an arbitrary miss
        # (direct IP, other vhosts) must stay an undecorated 404. The
        # loopback literal carries the port the caller used, so the hint
        # names a URL that answers on the same listener.
        private def localhost_hint(hostname : String?, env : ::HTTP::Server::Context) : String?
          return nil unless hostname == "localhost"
          host_header = env.request.headers["Host"]?
          port = host_header.try(&.split(':', 2)[1]?)
          loopback = port && !port.empty? ? "http://127.0.0.1:#{port}" : "http://127.0.0.1"
          configured = Util::ScriptHelpers.normalize_host(Facet::Config.instance.host)
          "Facet does not answer at localhost. Use the configured host (#{configured}) or the loopback literal (#{loopback})."
        end

        private def not_found(env, hint : String? = nil) : Nil
          env.response.status_code = 404
          env.response.content_type = "application/json"
          Facet::HTTP::Helpers.no_store(env)
          if hint
            env.response.print({error: "Not found", hint: hint}.to_json)
          else
            env.response.print({error: "Not found"}.to_json)
          end
        end

        # The 404 for a Host outside the configured facet host set. The
        # bare body reads as "the API is missing" — a reverse proxy whose
        # Host header does not match `host` / `base_url` gets this answer
        # for every path, and nothing in the body says the header was
        # rejected. The hint names the host and where the set comes from;
        # the habitual `localhost` miss keeps its own routing hint, which
        # names a URL that answers on the same listener.
        private def unknown_host(env, hostname : String) : Nil
          env.response.status_code = 404
          env.response.content_type = "application/json"
          Facet::HTTP::Helpers.no_store(env)
          hint = localhost_hint(hostname, env) ||
                 "host '#{hostname}' is not in the configured host set " \
                 "(host, base_url, artifact_base_url; see Facet::Util::ScriptHelpers.facet_hosts)"
          env.response.print({error: "Not found", hint: hint}.to_json)
        end
      end

      # ── Serving ────────────────────────────────────────────────────────

      # Resolves the app's active deployment and streams the mapped file.
      # Every dispatch miss is a bare 404 — no detail about which step
      # failed (unknown host shape, inactive app, missing deployment all
      # look identical from the outside). A path miss answers 404 too,
      # unless the request is a page load and the deployment sets `spa`
      # — then the shell answers.
      def self.serve(env, app_id : String) : Nil
        Database.with_db(:read_only) do |db|
          app = load_app(db, app_id)
          return not_found(env) unless app

          status = app.as_h["status"]?.try(&.as_s?) || "draft"
          return not_found(env) unless status == "active"

          deployment_ref = app.as_h["active_deployment"]?.try(&.as_s?)
          return not_found(env) unless deployment_ref

          deployment_id = bare_id(deployment_ref, "app.Deployment.")
          deployment = load_deployment(db, deployment_id)
          return not_found(env) unless deployment

          files = files_map(deployment)
          spa = deployment.as_h["spa"]?.try(&.as_bool?) != false
          spa = false unless navigation?(env)

          artifact_id = resolve_artifact_id(env.request.path, files, spa)
          return not_found(env) unless artifact_id

          artifact = Facet::Artifact::Store.find_artifact(db, artifact_id)
          return not_found(env) unless artifact
          return not_found(env) if artifact.deleted_at

          # The shell is whatever the files map (or the SPA fallback) resolved
          # to for `index.html` — the entry document a deploy replaces.
          shell = artifact_id == files["index.html"]?
          stream(env, artifact, cache_control: shell ? SHELL_CACHE_CONTROL : CACHE_CONTROL)
        end
      end

      # True when the request is a page load: a navigation mode, or no
      # Fetch Metadata at all (old browsers, command-line tools). The
      # lenient default keeps deep links and refreshes working wherever
      # the header is absent; browsers that do send the header mark every
      # asset fetch explicitly, and those never fall back.
      private def self.navigation?(env) : Bool
        mode = env.request.headers["Sec-Fetch-Mode"]?
        mode.nil? || NAVIGATION_MODES.includes?(mode)
      end

      # Maps the request path to a `files[].path` entry. Exact match only;
      # the root falls back to `index.html`; an unmatched path falls back
      # to `index.html` when the deployment's `spa` flag is set and the
      # request is a page load (`navigation?`).
      private def self.resolve_artifact_id(
        request_path : String,
        files : Hash(String, String),
        spa : Bool,
      ) : String?
        decoded = begin
          URI.decode(request_path)
        rescue ArgumentError
          request_path
        end
        relative = decoded.lstrip('/')
        return files["index.html"]? if relative.empty?

        files[relative]? || (files["index.html"]? if spa)
      end

      # Builds the `path → artifact id` map from the deployment's files
      # array. Entries without an artifact id are skipped (the deploy route
      # rejects them, but a directly-authored document must still degrade
      # to a 404 for that path, not a 500).
      private def self.files_map(deployment : JSON::Any) : Hash(String, String)
        map = {} of String => String
        entries = deployment.as_h["files"]?.try(&.as_a?) || [] of JSON::Any
        entries.each do |entry|
          hash = entry.as_h?
          next unless hash
          path = hash["path"]?.try(&.as_s?)
          artifact_id = hash["file"]?.try(&.as_s?)
          next if path.nil? || path.empty? || artifact_id.nil? || artifact_id.empty?
          map[path] = artifact_id
        end
        map
      end

      # Streams the artifact with the hosting header set: `Content-Type`
      # from the mime type stored on the artifacts row. The row decides
      # the type once, at upload time, on the server — from the file name
      # for deploy files, from the magic bytes for every other upload —
      # never from the request. `X-Content-Type-Options: nosniff` follows,
      # plus the caller's cache policy (`no-cache` for the app shell,
      # `CACHE_CONTROL` for every other asset). No restrictive CSP and no
      # `Content-Disposition` — this is the app's own site, not a download.
      private def self.stream(
        env,
        artifact : Facet::Artifact::Store::Artifact,
        cache_control : String,
      ) : Nil
        io = Facet::Artifact::Uploader.open(artifact.path)
        env.response.headers["Content-Type"] = artifact.mime_type
        env.response.headers["X-Content-Type-Options"] = "nosniff"
        env.response.headers["Cache-Control"] = cache_control

        if env.request.method == "HEAD"
          env.response.headers["Content-Length"] = artifact.size.to_s
          env.response.status_code = 200
          return
        end

        env.response.status_code = 200
        env.response.headers["Content-Length"] = artifact.size.to_s
        IO.copy(io, env.response)
      ensure
        io.try(&.close) rescue nil
      end

      private def self.not_found(env) : Nil
        env.response.status_code = 404
        env.response.content_type = "application/json"
        Facet::HTTP::Helpers.no_store(env)
        env.response.print({error: "Not found"}.to_json)
      end

      private def self.load_app(db : DB::Connection, app_id : String) : JSON::Any?
        db.query_one?(
          "SELECT content FROM projections WHERE id = $1 AND domain = 'app' AND doc_type = 'App' AND deleted_at IS NULL",
          app_id,
          as: JSON::Any,
        )
      end

      private def self.load_deployment(db : DB::Connection, deployment_id : String) : JSON::Any?
        db.query_one?(
          "SELECT content FROM projections WHERE id = $1 AND domain = 'app' AND doc_type = 'Deployment' AND deleted_at IS NULL",
          deployment_id,
          as: JSON::Any,
        )
      end

      # Reference values are stored fully qualified as
      # `{domain}.{Doctype}.{id}`; the projection id is the bare ULID.
      private def self.bare_id(qualified : String, prefix : String) : String
        qualified.starts_with?(prefix) ? qualified[prefix.size..] : qualified
      end
    end
  end
end
