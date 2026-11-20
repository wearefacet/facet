# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "kemal"
require "json"
require "../util/script_helpers"
require "./hosting"

module Facet
  module App
    # Caddy On-Demand TLS permission endpoint (the `ask` endpoint).
    #
    # The release Caddyfile's catch-all site block serves every host that
    # is not Facet's own main vhost — the `app.<slug>` naming convention.
    # Caddy issues a certificate for such a name at the first TLS
    # handshake, but only after it asks a permission endpoint. This route
    # is that endpoint:
    #
    # - `200` when an active `app.App` claims the host — Caddy may issue
    #   (internal CA on local names, ACME on public ones);
    # - `404` otherwise — Caddy denies, the handshake fails with a TLS
    #   error, and an unapproved host never produces an HTTP request.
    #
    # ## Wire contract (Caddy `tls.permission.http`)
    #
    # Caddy issues the check as a plain GET and sets the queried name in
    # the **`domain`** query parameter (`?domain=<name>`); any 2xx status
    # approves, any other status denies. Both sides of that contract are
    # Caddy-fixed — the parameter name and the status interpretation are
    # not configurable, so this endpoint must speak them verbatim.
    #
    # ## Rules
    #
    # - Public route (`AuthHandler::PUBLIC_ROUTES`, GET) — Caddy holds no
    #   session, and the check must run before any certificate exists.
    # - Never approves a Facet own-host (the
    #   `Util::ScriptHelpers.facet_hosts` reserved set: configured hosts,
    #   loopback literals, the `backend` service name). The main vhost
    #   has an explicit site block and never triggers on-demand; the
    #   guard is defence in depth.
    # - Reads `App::Hosting::HostCache.app_for_host` — the in-memory
    #   cache with a staleness bound, so an unknown-host handshake storm
    #   costs no per-request database read.
    # - No request body, no cookies read, one query-string parameter, no
    #   state change.
    module HostAsk
      Log = ::Log.for("facet.app.host_ask")

      def self.register : Nil
        get "/Edge/HostAsk" do |env|
          handle(env)
        end
      end

      private def self.handle(env) : Nil
        raw = env.request.query_params["domain"]?
        host = raw ? Util::ScriptHelpers.normalize_host(raw) : ""

        approved = !host.empty? &&
                   !Util::ScriptHelpers.facet_hosts.includes?(host) &&
                   !Hosting::HostCache.app_for_host(host).nil?

        unless approved
          Log.debug { "Host-ask denied: #{host.inspect}" }
        end

        env.response.status_code = approved ? 200 : 404
        env.response.content_type = "application/json"
        env.response.headers["Cache-Control"] = "no-store"
        env.response.print(approved ? {status: "ok"}.to_json : {error: "Not found"}.to_json)
      end
    end
  end
end
