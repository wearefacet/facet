# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "http/client"
require "uri"

module Facet
  module IAM
    module OIDC
      Log = ::Log.for("facet.iam.oidc")

      # Error raised by every denied OIDC step. The `code` is stable and
      # machine-readable for the audit log; the browser only ever sees the
      # generic denial.
      class Error < ::RuntimeError
        getter code : String

        def initialize(@code : String, message : String)
          super(message)
        end
      end

      # Result of one HTTP fetch: status plus raw body.
      alias FetchResult = NamedTuple(status: Int32, body: String)

      # The single injectable HTTP entry point for the OIDC subsystem.
      # Discovery, JWKS, and the token exchange all go through `call` —
      # specs replace `impl` to serve responses without a live IdP (the
      # project ships no WebMock; cross-check note 2.2.7).
      module Fetcher
        TIMEOUT = 5.seconds

        @@impl : Proc(String, String?, ::HTTP::Headers, String?, FetchResult)? = nil

        # Replaces the fetch implementation. Production code never calls
        # this — specs install a stub and `reset!` afterwards.
        def self.impl=(proc : Proc(String, String?, ::HTTP::Headers, String?, FetchResult)) : Nil
          @@impl = proc
        end

        def self.reset! : Nil
          @@impl = nil
        end

        # Performs `method` against `url`. Network failures degrade to a
        # `status: 0` result — every caller treats any non-200 as a deny.
        def self.call(
          method : String,
          url : String,
          headers : ::HTTP::Headers = ::HTTP::Headers.new,
          body : String? = nil,
        ) : FetchResult
          if impl = @@impl
            return impl.call(method, url, headers, body)
          end

          client = ::HTTP::Client.new(URI.parse(url))
          client.connect_timeout = TIMEOUT
          client.read_timeout = TIMEOUT
          response = case method.upcase
                     when "POST"
                       client.post(url, headers, body || "")
                     else
                       client.get(url, headers)
                     end
          {status: response.status_code, body: response.body}
        rescue ex
          Log.warn { "OIDC fetch failed (#{method} #{url}): #{ex.message}" }
          {status: 0, body: ""}
        end
      end

      record Endpoints,
        authorization : String,
        token : String,
        jwks_uri : String

      record JWK,
        kty : String,
        kid : String?,
        alg : String?,
        crv : String?,
        n : String?,
        e : String?,
        x : String?,
        y : String?

      # OIDC discovery + JWKS cache. The discovery document and the key set
      # are fetched once per issuer and cached for `TTL`. An unknown `kid`
      # (key rotation) triggers exactly one forced JWKS refresh — the
      # rotation path, not a general re-fetch loop.
      module Discovery
        TTL = 300.seconds

        @@endpoints = {} of String => {Endpoints, Time::Instant}
        @@keys = {} of String => {Hash(String, JWK), Time::Instant}

        # Clears both caches. Production calls this never — specs use it
        # between examples so a stubbed fetcher is not shadowed by cached
        # state.
        def self.reset! : Nil
          @@endpoints.clear
          @@keys.clear
        end

        # Fetches (or returns the cached) discovery endpoints for an issuer.
        # Raises `Error` with code `discovery_failed` on any failure — the
        # caller denies the login (fail closed).
        def self.endpoints(issuer : String) : Endpoints
          if cached = @@endpoints[issuer]?
            return cached[0] if Time.instant - cached[1] < TTL
            @@endpoints.delete(issuer)
          end

          raw = fetch_json("#{issuer}/.well-known/openid-configuration", "discovery document")
          endpoints = Endpoints.new(
            authorization: string_member(raw, "authorization_endpoint", issuer),
            token: string_member(raw, "token_endpoint", issuer),
            jwks_uri: string_member(raw, "jwks_uri", issuer),
          )
          @@endpoints[issuer] = {endpoints, Time.instant}
          endpoints
        end

        # Returns the JWKS keys of an issuer indexed by `kid`. Set `refresh`
        # to force a re-fetch — the unknown-`kid` path calls this once.
        def self.keys(issuer : String, jwks_uri : String, refresh : Bool = false) : Hash(String, JWK)
          unless refresh
            if cached = @@keys[issuer]?
              return cached[0] if Time.instant - cached[1] < TTL
              @@keys.delete(issuer)
            end
          end

          raw = fetch_json(jwks_uri, "JWKS")
          nodes = raw["keys"]?.try(&.as_a?)
          unless nodes
            raise Error.new("discovery_failed", "JWKS of issuer #{issuer} has no 'keys' array")
          end

          by_kid = {} of String => JWK
          nodes.each do |node|
            jwk = parse_jwk(node)
            if kid = jwk.kid
              by_kid[kid] = jwk
            end
          end
          @@keys[issuer] = {by_kid, Time.instant}
          by_kid
        end

        # ── Private ────────────────────────────────────────────────────────

        private def self.fetch_json(url : String, what : String) : JSON::Any
          result = Fetcher.call("GET", url)
          unless result[:status] == 200
            raise Error.new("discovery_failed", "Fetching the OIDC #{what} failed (HTTP #{result[:status]})")
          end
          JSON.parse(result[:body])
        rescue ex : Error
          raise ex
        rescue JSON::ParseException
          raise Error.new("discovery_failed", "The OIDC #{what} is not valid JSON")
        end

        private def self.string_member(raw : JSON::Any, member : String, issuer : String) : String
          value = raw[member]?.try(&.as_s?)
          unless value
            raise Error.new("discovery_failed", "Discovery document of #{issuer} is missing '#{member}'")
          end
          value
        end

        private def self.parse_jwk(node : JSON::Any) : JWK
          h = node.as_h?
          unless h
            raise Error.new("discovery_failed", "JWKS entry is not a JSON object")
          end
          JWK.new(
            kty: h["kty"]?.try(&.as_s?) || "",
            kid: h["kid"]?.try(&.as_s?),
            alg: h["alg"]?.try(&.as_s?),
            crv: h["crv"]?.try(&.as_s?),
            n: h["n"]?.try(&.as_s?),
            e: h["e"]?.try(&.as_s?),
            x: h["x"]?.try(&.as_s?),
            y: h["y"]?.try(&.as_s?),
          )
        end
      end
    end
  end
end
