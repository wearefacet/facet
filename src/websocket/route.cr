# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "kemal"
require "../config"
require "../http/auth_handler"
require "../rbac/auth_context"
require "../oauth/origin_cache"
require "./connection"
require "./manager"

module Facet
  module Websocket
    # Registers the Kemal WebSocket `/Ws` handler.
    #
    # Authentication is performed at upgrade time. Three transports exist:
    #
    # - Cookie — `auth_token`, same-origin browser sessions.
    # - `Authorization: Bearer/DPoP` — header-capable clients (Node, CLI).
    # - `Sec-WebSocket-Protocol` — browser apps. The SDK offers
    #   `["#{TOKEN_PROTOCOL}", <app JWT>]` because a browser cannot set
    #   `Authorization` on an upgrade and the `auth_token` cookie does not
    #   travel cross-site (SameSite=Lax). Only `typ: "app"` JWTs are accepted
    #   on this transport; `HTTP::AuthHandler` enforces that.
    #
    # Only authenticated connections are upgraded; invalid or missing tokens
    # receive a 4401 close frame. Origin is validated per request against
    # `Config.instance.host` plus the origins registered on active `app.App`
    # documents (`OAuth::OriginCache`), mirroring `OAuth::Cors`.
    module Route
      CLOSE_AUTH_FAILED   = 4401
      CLOSE_ORIGIN_DENIED = 4403

      # Subprotocol name the SDK offers at handshake: client sends
      # `Sec-WebSocket-Protocol: facet-ws-v1, <app JWT>`; the server answers
      # with this name and reads the credential from the second entry. The
      # name must stay dot-free — the token-detection shape is three
      # dot-separated segments, and a dotted protocol name would match it.
      TOKEN_PROTOCOL = "facet-ws-v1"

      # Kemal handler context-store key carrying the subprotocol token from
      # the handshake handler to the route block. Values are strings only.
      CONTEXT_TOKEN_KEY = "ws.subprotocol.token"

      # Shape of a JWT (`header.payload.signature`, base64url segments). Used
      # to tell a credential entry from a plain subprotocol name — clients
      # may offer other protocols, and those must not break cookie/header
      # authentication.
      JWT_SHAPE = /^[\w-]+\.[\w-]+\.[\w-]+$/

      # Register the `ws "/Ws"` route.
      def self.register : Nil
        compiled_origin = build_origin_regex

        # Kemal 1.13 rejects upgrades whose Origin is absent (header-capable
        # clients) or not same-origin (browser apps) before the route block
        # runs. The `"*"` escape hatch moves origin enforcement down to the
        # per-request allowlist check inside the block — same guarantee, one
        # notch later (post-upgrade 4403 close instead of an HTTP 403).
        Kemal.config.websocket_allowed_origins = ["*"]

        # Prepares the subprotocol transport before the upgrade headers are
        # written (see `HandshakeHandler`).
        Kemal.config.add_handler(HandshakeHandler.new)

        ws "/Ws" do |socket, env|
          # 1. Origin check
          origin = env.request.headers["Origin"]?
          # Origin null is safe; non-browser clients do not send it. This
          # allows API/curl-style access to the websocket without extra step.
          if origin && !origin_allowed?(origin, compiled_origin)
            Log.warn { "WS connection rejected: origin '#{origin}' not allowed" }
            socket.close(CLOSE_ORIGIN_DENIED, "Origin not allowed")
            next
          end

          # 2. Cookie/Bearer/subprotocol auth → AuthContext (delegates to the
          #    AuthHandler class methods for DRY, transport-independent logic)
          auth_context = if HTTP::AuthHandler.enabled?
                           subprotocol_token = env.get?(CONTEXT_TOKEN_KEY).as?(String)
                           if subprotocol_token
                             HTTP::AuthHandler.auth_context_from_token(
                               env,
                               subprotocol_token,
                               HTTP::AuthHandler::WS_SUBPROTOCOL,
                             )
                           else
                             HTTP::AuthHandler.auth_context_from_request(env)
                           end
                         else
                           RBAC::AuthContext.system
                         end

          if auth_context.nil?
            socket.close(CLOSE_AUTH_FAILED, "Authentication required")
            next
          end

          # 3. Build the connection; `conn.run` sets up event handlers
          #    and blocks until the socket closes. The connection is tracked
          #    with the Manager as soon as it is live, so the shutdown path
          #    can close it even before a subscription registers it under a
          #    channel (`cleanup` untracks).
          conn = Connection.new(socket, auth_context)
          Manager.instance.track(conn)
          conn.run
        end

        Log.info { "WebSocket route /Ws registered" }
      end

      # Origin allowlist for the upgrade: the configured `host` (the Facet
      # frontend) plus any origin registered on an active `app.App` — the
      # same set `OAuth::Cors` mirrors for `/Api/*`. Registered app origins
      # are the natural model for app-served WebSocket clients; the cache is
      # event-invalidated on every `app.App` mutation.
      def self.origin_allowed?(origin : String, compiled_origin : Regex) : Bool
        return true if origin.match(compiled_origin)
        OAuth::OriginCache.origin_allowed?(origin)
      end

      # Builds a Regex from the configured `host` for origin validation.
      #
      # `host` may carry a scheme (e.g. `https://localhost:3443` when a
      # reverse proxy like the dev Caddy setup terminates TLS in front of
      # Kemal) or be scheme-less (`localhost:3000`). A leading scheme is
      # stripped so this regex — not the config value — is the single source
      # of the `https?://` anchor; otherwise the pattern would double-prefix
      # the scheme and reject every real browser origin. The optional `host`
      # argument lets specs exercise scheme-bearing values without depending
      # on `config.{env}.yml`.
      def self.build_origin_regex(host : String = Config.instance.host) : Regex
        bare = host.sub(/^https?:\/\//, "")
        escaped = Regex.escape(bare)
        Regex.new("^https?://#{escaped}(:\\d+)?$")
      end

      # ── Subprotocol handshake ───────────────────────────────────────────

      # Runs before `Kemal::WebSocketHandler` in the chain, so it can shape
      # the headers that the 101 response is written from.
      #
      # When the request offers the bearer-token entry (`TOKEN_PROTOCOL` plus
      # a JWT-shaped subprotocol), the token is:
      #
      # 1. Stripped from the request `Sec-WebSocket-Protocol` header — no
      #    downstream layer can ever echo it back.
      # 2. Stashed in the Kemal context store for the route block.
      # 3. Answered with a `Sec-WebSocket-Protocol: facet-ws-v1` response
      #    header. Crystal's upgrade handler only overwrites that header when
      #    the handler was constructed with a fixed subprotocol list (Kemal
      #    passes none), so the pre-set value rides the 101. Browsers require
      #    the echo to come from the offered set — the protocol name is.
      #
      # Non-token protocol offers are left untouched: cookie/header
      # authentication proceeds unchanged and no protocol is echoed.
      class HandshakeHandler < Kemal::Handler
        def call(context : ::HTTP::Server::Context) : Nil
          request = context.request
          return call_next(context) unless route_token_protocol?(request)

          protocols = request.headers["Sec-WebSocket-Protocol"]
          entries = protocols.split(',').map(&.strip)
          bearer = entries.find(&.matches?(JWT_SHAPE))

          if bearer
            request.headers["Sec-WebSocket-Protocol"] = (entries - [bearer]).join(",")
            context.set(CONTEXT_TOKEN_KEY, bearer)
            context.response.headers["Sec-WebSocket-Protocol"] = TOKEN_PROTOCOL
          end

          call_next(context)
        end

        private def route_token_protocol?(request : ::HTTP::Request) : Bool
          return false unless request.method == "GET"
          return false unless request.path == "/Ws"
          request.headers.has_key?("Sec-WebSocket-Protocol")
        end
      end
    end
  end
end
