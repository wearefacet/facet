# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "../config"

module Facet
  module OAuth
    # Discovery metadata for the Facet app authorization server.
    #
    # Issued at `GET /.well-known/oauth-authorization-server`. Cheap, lets
    # generated apps use off-the-shelf OAuth libraries rather than
    # hand-rolling the flow. The metadata describes the Facet *app*
    # authorization server only — these endpoints are not a general
    # OAuth provider for arbitrary third parties.
    #
    # Issuer is the configured `host`. The `code_challenge_methods_supported`
    # array contains only `S256` — `plain` is rejected (see `Authorize`).
    module Discovery
      # Returns the discovery metadata as a `JSON::Any` hash. Routes
      # serialize it to JSON for the HTTP response.
      def self.metadata : JSON::Any
        base = issuer
        h = {} of String => JSON::Any
        h["issuer"] = JSON::Any.new(base)
        h["authorization_endpoint"] = JSON::Any.new("#{base}/OAuth/authorize")
        h["token_endpoint"] = JSON::Any.new("#{base}/OAuth/token")
        # RFC 7591 — dynamic client registration. The MCP authorization spec
        # requires clients to self-register; without this member a
        # spec-compliant client stops at discovery (opencode: "does not
        # support dynamic client registration"). See `OAuth::Register`.
        h["registration_endpoint"] = JSON::Any.new("#{base}/OAuth/register")
        h["response_types_supported"] = JSON::Any.new([JSON::Any.new("code")] of JSON::Any)
        h["grant_types_supported"] = JSON::Any.new([
          JSON::Any.new("authorization_code"),
          JSON::Any.new("refresh_token"),
        ] of JSON::Any)
        h["code_challenge_methods_supported"] = JSON::Any.new([JSON::Any.new("S256")] of JSON::Any)
        h["token_endpoint_auth_methods_supported"] = JSON::Any.new([
          JSON::Any.new("none"), # public clients (PKCE) only
        ] of JSON::Any)
        # DPoP — the only sender-constraining method supported. The
        # array advertises supported signing algorithms for the DPoP proof JWT;
        # the verifier is pinned to ES256, so the array contains only that.
        h["dpop_signing_alg_values_supported"] = JSON::Any.new([JSON::Any.new("ES256")] of JSON::Any)
        h["scopes_supported"] = JSON::Any.new([] of JSON::Any) # no fixed scope vocabulary
        # RFC 9207 — the authorization response carries `iss` alongside
        # `code`/`state`. Strict clients consult this flag to decide whether
        # to require the parameter before redeeming a code.
        h["authorization_response_iss_parameter_supported"] = JSON::Any.new(true)
        JSON::Any.new(h)
      end

      # The issuer identifier — the same value carried in discovery, the
      # RFC 9207 `iss` authorization-response parameter, and the MCP PRM's
      # authorization-server entry. Single source so the three can never
      # drift apart.
      #
      # Scheme normalization lives in `Config#scheme_base_url` so `host` may
      # be scheme-bearing (reverse-proxied, e.g. `https://localhost:3443`) or
      # scheme-less (`localhost:3000`) without this site re-implementing the
      # `http(s)://` prefix logic.
      def self.issuer : String
        Facet::Config.instance.scheme_base_url
      end
    end
  end
end
