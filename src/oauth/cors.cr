# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "kemal"

module Facet
  module OAuth
    # CORS handler for app-registered origins.
    #
    # Runs early in the Kemal handler chain (before `AuthHandler`). Adds CORS
    # headers to responses on:
    #
    # - `OPTIONS /OAuth/token` — preflight for the token endpoint
    # - `OPTIONS /OAuth/register` — preflight for the registration
    #   endpoint
    # - `OPTIONS /OAuth/client-info` — preflight for the public client
    #   metadata endpoint (the slug → client_id lookup a SPA ships with)
    # - `OPTIONS /Api/*` — preflight for the document API when called with
    #   an app bearer token from a browser context (apps are internal and
    #   may run on a different origin than Facet)
    # - `POST /OAuth/token`, `POST /OAuth/register`, and `/Api/*`
    #   actual responses — the `Access-Control-Allow-Origin` header is
    #   echoed back when the request `Origin` is registered on some
    #   `app.App.allowed_origins`
    #
    # ## Why echo, not `*`
    #
    # Browsers ignore `Access-Control-Allow-Origin: *` when `Authorization`
    # is in `Access-Control-Allow-Headers`. We echo the exact request origin
    # back — the cache validator is `Vary: Origin`.
    #
    # ## Origin matching
    #
    # The `Origin` header is matched exactly against the registered origins
    # via `OriginCache`. No normalization, no wildcards — same rule as
    # `redirect_uri` on the authorize endpoint.
    class Cors < Kemal::Handler
      # Routes on which CORS is applied. Booleans:
      # - `:preflight_only` — respond 204 to OPTIONS, add headers to actual
      #   responses.
      # - `:actual_only` — skip OPTIONS handling, add headers to actual
      #   responses.
      private def cors_path?(path : String) : Bool
        return true if path == "/OAuth/token"
        return true if path.starts_with?("/OAuth/token")
        return true if path == "/OAuth/register"
        return true if path == "/OAuth/client-info"
        return true if path.starts_with?("/Api/")
        return true if path == "/.well-known/oauth-authorization-server"
        false
      end

      # Routes that answer OPTIONS with the 204 preflight — every CORS-
      # enabled endpoint that browsers call cross-origin. One table so
      # `call` stays a simple dispatch (the handler runs on every request;
      # ameba's complexity budget applies).
      private PREFLIGHT_PATHS = {
        "/OAuth/token",
        "/OAuth/register",
        "/OAuth/client-info",
        "/.well-known/oauth-authorization-server",
      }

      def call(env)
        path = env.request.path
        method = env.request.method

        if method == "OPTIONS" && (PREFLIGHT_PATHS.includes?(path) || path.starts_with?("/Api/"))
          return preflight(env)
        end

        # Actual requests: if the origin is allowed, mirror the CORS header.
        if cors_path?(path)
          origin = env.request.headers["Origin"]?
          if origin && OriginCache.origin_allowed?(origin)
            env.response.headers["Access-Control-Allow-Origin"] = origin
            env.response.headers["Access-Control-Allow-Credentials"] = "true"
            env.response.headers["Vary"] = vary_with_origin(env.response.headers["Vary"]?)
          end
        end

        call_next(env)
      end

      # ── Internals ──────────────────────────────────────────────────────

      private def preflight(env) : Nil
        env.response.status_code = 204
        # Browsers preflight a method that is not on the CORS-safelist. The
        # list must name each method the API serves. `QUERY` (RFC 10008) and
        # the write verbs `PATCH`, `PUT`, `DELETE` are not safelisted.
        # `GET` and `POST` are safelisted; the list keeps them, so a client
        # that preflights them still gets an answer.
        env.response.headers["Access-Control-Allow-Methods"] = "GET, POST, PATCH, PUT, DELETE, QUERY, OPTIONS"
        # `DPoP` must be declared: a sender-constrained token is presented as
        # `Authorization: DPoP …` on the actual request and every proof rides
        # the `DPoP` header — a browser preflight for either is
        # rejected without it.
        env.response.headers["Access-Control-Allow-Headers"] = "Authorization, Content-Type, X-Requested-With, DPoP"
        env.response.headers["Access-Control-Max-Age"] = "600"

        origin = env.request.headers["Origin"]?
        if origin && OriginCache.origin_allowed?(origin)
          env.response.headers["Access-Control-Allow-Origin"] = origin
          env.response.headers["Access-Control-Allow-Credentials"] = "true"
          env.response.headers["Vary"] = vary_with_origin(env.response.headers["Vary"]?)
        else
          # No CORS headers when the origin is not registered. The browser
          # will block the actual request.
          env.response.headers["Vary"] = vary_with_origin(env.response.headers["Vary"]?)
        end
      end

      private def vary_with_origin(existing : String?) : String
        return "Origin" if existing.nil? || existing.empty?
        return existing if existing.split(',').map(&.strip).includes?("Origin")
        "#{existing}, Origin"
      end
    end
  end
end
