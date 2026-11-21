# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "kemal"
require "./helpers"
require "./responders"

module Facet
  module HTTP
    # Kemal handler that enforces the CSRF admission gate on every mutating
    # request, one position in front of `AuthHandler`.
    #
    # Browser sessions are cookie-authenticated, so a cross-site request
    # cannot legitimately carry the `X-Requested-With` header. A request that
    # rides the `auth_token` cookie must therefore present a non-blank
    # `X-Requested-With` header on every method that can change state;
    # otherwise the handler answers `403` with the shared CSRF body. The
    # check is pure request inspection — method, cookie presence, headers —
    # so it runs before any auth state exists and never depends on it.
    #
    # A request passes the gate when any of these holds:
    #
    # - The method is `GET`, `HEAD`, or `OPTIONS` — nothing to forge.
    # - No `auth_token` cookie rides the request: there is no ambient
    #   credential to abuse, so login-style flows stay ungated.
    # - `Helpers.non_ambient_credential?` is true: a `Bearer`/`DPoP`
    #   Authorization credential without the session cookie. Browsers never
    #   attach an Authorization header to cross-site requests, so such a
    #   credential cannot be replayed by a CSRF forgery.
    # - The path is listed in `EXEMPT_PATHS`.
    #
    # A request that carries an Authorization header beside the session
    # cookie stays gated — the cookie is the ambient credential this defense
    # exists for. The per-route `Helpers.require_csrf` calls remain as
    # defense in depth: this handler closes the forgotten-call hole, the
    # route-level gate keeps enforcing the check on the routes that declare
    # it.
    class CsrfHandler < Kemal::Handler
      # Exact-match path opt-outs for a third-party browser flow that must
      # reach a mutating route without the `X-Requested-With` header (a
      # cross-site form POST can set no custom headers). The match is exact
      # against `env.request.path` — no prefixes, no parameters. Empty by
      # default: every cookie-authenticated mutating route known today is
      # called with the header or is exempt by one of the rules above.
      EXEMPT_PATHS = [] of String

      def call(env)
        method = env.request.method
        return call_next(env) if method == "GET" || method == "HEAD" || method == "OPTIONS"
        return call_next(env) unless env.request.cookies["auth_token"]?
        return call_next(env) if Helpers.non_ambient_credential?(env)
        return call_next(env) if EXEMPT_PATHS.includes?(env.request.path)

        header = env.request.headers["X-Requested-With"]?
        if header.nil? || header.blank?
          Responders.error_response(env, 403, "CSRF: Missing X-Requested-With header")
          return
        end

        call_next(env)
      end
    end
  end
end
