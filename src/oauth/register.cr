# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "./endpoint_error"
require "./redirect_uri"

module Facet
  module OAuth
    # RFC 7591 dynamic client registration for the MCP surface.
    #
    # Serves `POST /OAuth/register`. The MCP authorization spec requires
    # clients to self-register before they can start the PKCE authorize flow;
    # `Discovery` advertises this endpoint as `registration_endpoint` so a
    # spec-compliant client (opencode, MCP Inspector, …) finds it during
    # discovery instead of failing with "does not support dynamic client
    # registration".
    #
    # ## Stateless by decision
    #
    # The registration keeps no record. The MCP branch of `Authorize` /
    # `Token` treats `client_id` as an opaque string bound to the
    # authorization code (MCP is not an app — no `app.App` row, no
    # `GrantResolver`), so the consent screen, PKCE, and the code's
    # `client_id` / `redirect_uri` bindings carry the security. The endpoint
    # only validates the client-metadata shape and mints an opaque
    # public-client id; a persisted registry would buy a client name on the
    # consent screen and a revocation list at the cost of spam management.
    #
    # ## Errors
    #
    # RFC 7591 §3.2.2 — `invalid_redirect_uri` when a `redirect_uris` entry
    # is unusable, `invalid_client_metadata` for every other violation.
    module Register
      # The registration endpoint's error type. Same 400 default as the
      # other OAuth endpoint errors; the route renders it through the
      # shared RFC 6749 §5.2 error body.
      class Error < EndpointError
      end

      # Minted-id entropy — 32 random bytes, url-safe base64 (the same
      # entropy `OAuth::CodeStore` uses for authorization codes).
      CLIENT_ID_BYTES = 32

      # The grant types and response types every registered client may use.
      # Facet supports the PKCE authorization-code flow with refresh
      # rotation and nothing else; the registration response mirrors that
      # fixed set.
      SUPPORTED_GRANT_TYPES    = ["authorization_code", "refresh_token"]
      SUPPORTED_RESPONSE_TYPES = ["code"]

      # The successful registration. `client_id` is opaque and public —
      # there is no secret (Facet serves public clients only).
      record Metadata,
        client_id : String,
        client_id_issued_at : Int64,
        redirect_uris : Array(String),
        client_name : String?

      # Validates the posted client metadata and mints a public client.
      # Raises `Error` on any violation. Unknown metadata members are
      # ignored per RFC 7591 §2.
      def self.call(metadata : JSON::Any) : Metadata
        redirect_uris = extract_redirect_uris(metadata)
        check_token_endpoint_auth_method(metadata)
        check_string_array(metadata, "grant_types", SUPPORTED_GRANT_TYPES)
        check_string_array(metadata, "response_types", SUPPORTED_RESPONSE_TYPES)

        Metadata.new(
          client_id: Random::Secure.urlsafe_base64(CLIENT_ID_BYTES),
          client_id_issued_at: Time.utc.to_unix,
          redirect_uris: redirect_uris,
          client_name: optional_string(metadata, "client_name"),
        )
      end

      # Builds the RFC 7591 §3.2.1 registration response body: the minted
      # client identity plus the metadata the server actually applies.
      def self.response(metadata : Metadata) : JSON::Any
        h = {} of String => JSON::Any
        h["client_id"] = JSON::Any.new(metadata.client_id)
        h["client_id_issued_at"] = JSON::Any.new(metadata.client_id_issued_at)
        h["redirect_uris"] = JSON::Any.new(metadata.redirect_uris.map { |u| JSON::Any.new(u) })
        h["token_endpoint_auth_method"] = JSON::Any.new("none")
        h["grant_types"] = JSON::Any.new(SUPPORTED_GRANT_TYPES.map { |g| JSON::Any.new(g) })
        h["response_types"] = JSON::Any.new(SUPPORTED_RESPONSE_TYPES.map { |t| JSON::Any.new(t) })
        h["client_name"] = JSON::Any.new(metadata.client_name) if metadata.client_name
        JSON::Any.new(h)
      end

      # ── Internals ────────────────────────────────────────────────────────

      # `redirect_uris` is required for an authorization-code client. Every
      # entry must pass the shared shape rule (`Util::RedirectUri` through
      # `OAuth::RedirectUri.valid_shape?`): `https` on any host, or `http`
      # on a loopback host only (`localhost`, any `*.localhost` subdomain,
      # `127.0.0.1`, `::1`) — RFC 8252 §7.3; a native client listens on an
      # OS-assigned port, so the `*` wildcard-port form is accepted the
      # same way `app.App` registrations accept it.
      private def self.extract_redirect_uris(metadata : JSON::Any) : Array(String)
        raw = metadata["redirect_uris"]?
        unless raw && raw.as_a?
          raise Error.new("invalid_client_metadata",
            "'redirect_uris' is required and must be an array of strings", 400)
        end

        uris = raw.as_a.compact_map(&.as_s?)
        if uris.empty? || uris.size != raw.as_a.size
          raise Error.new("invalid_client_metadata",
            "'redirect_uris' must be an array of strings", 400)
        end

        uris.each do |uri|
          unless RedirectUri.valid_shape?(uri)
            raise Error.new("invalid_redirect_uri",
              "'redirect_uris' entry is not a usable redirect URI: #{uri} — " \
              "https is allowed on any host, http only on a loopback host " \
              "(localhost, *.localhost, 127.0.0.1, ::1)", 400)
          end
        end
        uris
      end

      # Facet serves public clients only — discovery's
      # `token_endpoint_auth_methods_supported` carries `none` alone. A
      # client asking for anything else could not use the token endpoint,
      # so it is rejected at registration rather than at the flow.
      private def self.check_token_endpoint_auth_method(metadata : JSON::Any) : Nil
        method = optional_string(metadata, "token_endpoint_auth_method")
        return if method.nil?
        return if method == "none"

        raise Error.new("invalid_client_metadata",
          "Only public clients (token_endpoint_auth_method=none) are supported", 400)
      end

      # Rejects a present-but-unsupported string-array member. Absent means
      # "server default" per RFC 7591 — the registration response names the
      # values the server applies.
      private def self.check_string_array(metadata : JSON::Any, name : String, supported : Array(String)) : Nil
        raw = metadata[name]?
        return unless raw
        values = raw.as_a?.try(&.compact_map(&.as_s?))
        if values.nil? || values.size != raw.as_a.size
          raise Error.new("invalid_client_metadata",
            "'#{name}' must be an array of strings", 400)
        end

        values.each do |value|
          next if supported.includes?(value)
          raise Error.new("invalid_client_metadata",
            "'#{name}' value '#{value}' is not supported", 400)
        end
      end

      # A required-to-be-string member when present; an empty value counts
      # as absent. A non-string value is a metadata violation.
      private def self.optional_string(metadata : JSON::Any, name : String) : String?
        value = metadata[name]?.try(&.as_s?)
        return nil if value.nil? || value.empty?
        value
      end
    end
  end
end
