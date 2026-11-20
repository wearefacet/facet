# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"
require "kemal"
require "base64"
require "openssl"
require "http/params"
require "uri"
require "../../database"
require "../../event"
require "../../http/helpers"
require "../../secrets/store"
require "../helpers"
require "../redis_session"
require "./providers"
require "./state"
require "./discovery"
require "./verify"
require "./identity"

module Facet
  module IAM
    module OIDC
      # Browser-facing routes for inbound federated login:
      #
      # - `GET /auth/oidc/:provider` — starts the flow: mints state + nonce
      #   + PKCE verifier, stores them one-shot in Redis, and 302s to the
      #   IdP's authorization endpoint.
      # - `GET /auth/oidc/:provider/callback` — consumes the state row
      #   first, exchanges the code (PKCE verifier attached), verifies the
      #   id_token, and resolves the identity. Success sets the session
      #   cookies and redirects to `/`; every denial redirects to
      #   `/Login?error=oidc_denied` — one generic code, no detail.
      #
      # Both routes are GET redirects — no CSRF guard needed. They are made
      # public through a prefix rule in `AuthHandler`.
      module Routes
        # Registers the OIDC routes on the Kemal router.
        def self.register : Nil
          # ── GET /auth/oidc/:provider ────────────────────────────
          get "/auth/oidc/:provider" do |env|
            provider = Database.with_db(:read_only) do |db|
              Providers.find(db, env.params.url["provider"])
            end
            next deny_redirect(env) unless provider

            endpoints = begin
              Discovery.endpoints(provider.issuer)
            rescue ex : Error
              Log.warn { "OIDC start failed: #{ex.message}" }
              next deny_redirect(env)
            end

            state = Random::Secure.hex(32)
            nonce = Random::Secure.hex(32)
            verifier = Random::Secure.urlsafe_base64(48)
            State.create(state, provider.name, nonce, verifier)

            query = ::URI::Params.build do |form|
              form.add("response_type", "code")
              form.add("client_id", provider.client_id)
              form.add("redirect_uri", redirect_uri(provider.name))
              form.add("scope", provider.scopes.join(" "))
              form.add("state", state)
              form.add("nonce", nonce)
              form.add("code_challenge", pkce_challenge(verifier))
              form.add("code_challenge_method", "S256")
            end
            env.redirect("#{endpoints.authorization}?#{query}")
          end

          # ── GET /auth/oidc/:provider/callback ──────────────────────
          get "/auth/oidc/:provider/callback" do |env|
            result = Database.with_db do |db|
              handle_callback(db, env)
            end
            Event::Publisher.flush

            case result
            in TokenEmitter::Result
              TokenEmitter.set_cookies(env, result)
              env.redirect("/")
            in Facet::ServiceError
              deny_redirect(env)
            end
          end
        end

        # ── Private ────────────────────────────────────────────────────────

        # Runs one callback attempt. Every failure path writes an
        # `oidc_denied` LoginEvent (detail only in the audit log) and
        # returns the generic `ServiceError`.
        private def self.handle_callback(db : DB::Connection, env) : TokenEmitter::Result | Facet::ServiceError
          provider = Providers.find(db, env.params.url["provider"])
          unless provider
            Helpers.write_login_event(db, "system:oidc", "oidc_denied", "Unknown or disabled provider")
            return Facet::ServiceError.new(401, "Login denied")
          end

          # Consume the state row before acting on it — a replayed or
          # fabricated state is denied here.
          stored = env.params.query["state"]?.try { |s| State.consume(s) }
          unless stored && stored.provider == provider.name
            Helpers.write_login_event(db, "system:oidc", "oidc_denied",
              "State missing, expired, consumed, or provider mismatch")
            return Facet::ServiceError.new(401, "Login denied")
          end

          code = env.params.query["code"]?
          unless code
            Helpers.write_login_event(db, "system:oidc", "oidc_denied", "Authorization response without code")
            return Facet::ServiceError.new(401, "Login denied")
          end

          payload = exchange_and_verify(db, provider, code, stored)
          return payload if payload.is_a?(Facet::ServiceError)

          claims = begin
            Identity::Claims.from_payload(payload)
          rescue ex : Error
            return deny(db, claims_audit_id(payload), "Claim extraction failed: #{ex.message}")
          end

          Identity.authenticate(db, provider, claims)
        end

        # Exchanges the authorization code and verifies the id_token.
        # Returns the verified payload or the generic `ServiceError`. The
        # client secret is revealed from the sealed store exactly here —
        # one AES-GCM open per exchange, never cached, never carried on
        # the provider record. A missing or unreadable slot denies (fail
        # closed): a provider without a usable secret cannot log anyone
        # in.
        private def self.exchange_and_verify(
          db : DB::Connection,
          provider : Provider,
          code : String,
          stored : State::Entry,
        ) : Hash(String, JSON::Any) | Facet::ServiceError
          endpoints = begin
            Discovery.endpoints(provider.issuer)
          rescue ex : Error
            return deny(db, "system:oidc", "Discovery failed: #{ex.message}")
          end

          client_secret = Secrets.reveal(db, "iam.OIDCProvider.#{provider.doc_id}", "client_secret")
          if client_secret.nil?
            return deny(db, "system:oidc",
              "Provider '#{provider.name}' has no readable client secret in the sealed store")
          end

          token_response = begin
            exchange(provider, client_secret, endpoints.token, code, stored.verifier)
          rescue ex : Error
            return deny(db, "system:oidc", "Token exchange failed: #{ex.message}")
          end

          id_token = token_response["id_token"]?.try(&.as_s?)
          unless id_token
            return deny(db, "system:oidc", "Token response carries no id_token")
          end

          begin
            Verify.call(id_token, provider, stored.nonce)
          rescue ex : Error
            deny(db, "system:oidc", "id_token verification failed: #{ex.code}")
          end
        end

        # Denial helper: audit event + generic error. The browser never
        # sees `reason` — it only lands in the LoginEvent details.
        private def self.deny(db : DB::Connection, account_id : String, reason : String) : Facet::ServiceError
          Helpers.write_login_event(db, account_id, "oidc_denied", reason)
          Facet::ServiceError.new(401, "Login denied")
        end

        # Best-effort audit subject from a verified payload (the `sub` is
        # the durable external identity — usable for the audit trail even
        # when no account matches).
        private def self.claims_audit_id(payload : Hash(String, JSON::Any)) : String
          payload["sub"]?.try(&.as_s?) || "system:oidc"
        end

        # Confidential-client token exchange: PKCE verifier attached, the
        # client secret rides in an HTTP Basic auth header — never in the
        # audit log. The secret arrives from `Secrets.reveal` and is
        # dropped when this frame returns.
        private def self.exchange(
          provider : Provider,
          client_secret : String,
          token_endpoint : String,
          code : String,
          verifier : String,
        ) : Hash(String, JSON::Any)
          form = ::URI::Params.build do |f|
            f.add("grant_type", "authorization_code")
            f.add("code", code)
            f.add("redirect_uri", redirect_uri(provider.name))
            f.add("code_verifier", verifier)
          end
          headers = ::HTTP::Headers{
            "Content-Type"  => "application/x-www-form-urlencoded",
            "Authorization" => "Basic #{Base64.strict_encode("#{provider.client_id}:#{client_secret}")}",
          }

          result = Fetcher.call("POST", token_endpoint, headers, form)
          unless result[:status] == 200
            raise Error.new("exchange_failed", "Token endpoint rejected the exchange (HTTP #{result[:status]})")
          end

          parsed = JSON.parse(result[:body]).as_h?
          unless parsed
            raise Error.new("exchange_failed", "Token response is not a JSON object")
          end
          parsed
        end

        # RFC 7636 §4.2: BASE64URL(SHA-256(verifier)), no padding.
        private def self.pkce_challenge(verifier : String) : String
          digest = OpenSSL::Digest.new("SHA256")
          digest.update(verifier)
          Base64.urlsafe_encode(digest.final, padding: false)
        end

        private def self.redirect_uri(provider_name : String) : String
          "#{Facet::Config.instance.scheme_base_url}/auth/oidc/#{provider_name}/callback"
        end

        # The single generic denial redirect — every failure funnels here.
        private def self.deny_redirect(env) : Nil
          env.redirect("/Login?error=oidc_denied")
        end
      end
    end
  end
end
