# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "yaml"

module Facet
  module IAM
    # Runtime configuration for the IAM subsystem.
    #
    # Delegates to `Facet::Config.instance.iam` for all settings.
    # Provides a clean namespace so IAM code doesn't import Config directly.
    module Config
      # JWT token lifetimes and grace window.
      def self.jwt : Facet::Config::JWTConfig
        Facet::Config.instance.iam.jwt
      end

      # MFA / TOTP settings.
      def self.mfa : Facet::Config::MFAConfig
        Facet::Config.instance.iam.mfa
      end

      # Password reset token TTL (seconds).
      def self.change_password_expiration : Int32
        Facet::Config.instance.iam.change_password_expiration
      end

      # Whether auth cookies are set with the Secure flag (HTTPS only).
      # Defaults to true; set to false in dev config for plain-HTTP localhost.
      def self.secure_cookies : Bool
        Facet::Config.instance.iam.secure_cookies
      end

      # Whether auth cookies are set with the Secure flag (HTTPS only).false

      # Reloads the config (useful in tests after calling Config.reset!).
      def self.reset! : Nil
        Config.instance
      end

      private def self.instance
        Facet::Config.instance
      end
    end
  end

  # ── `iam:` section of `Facet::Config` ────────────────────────────────
  #
  # The `iam:` records and their YAML loaders live here, next to the IAM
  # concern. `Facet::Config` (src/config.cr) declares the `iam` field and
  # calls `load_iam` when it parses the file. The type paths keep the
  # `Facet::Config::` prefix, so the `IAM::Config` facade above and every
  # other caller read them with no change.
  class Config
    # ── IAM Records ─────────────────────────────────────────────────────

    record IAMConfig,
      jwt : JWTConfig = JWTConfig.new,
      mfa : MFAConfig = MFAConfig.new,
      auth : AuthConfig = AuthConfig.new,
      oidc : OidcConfig = OidcConfig.new,
      change_password_expiration : Int32 = 86400,
      secure_cookies : Bool = true

    record JWTConfig,
      access_token_ttl : Int32 = 900,
      refresh_token_ttl : Int32 = 1_209_600,
      refresh_grace_window : Int32 = 10,
      dpop_iat_future_tolerance : Int32 = 10,
      dpop_iat_past_tolerance : Int32 = 30 do
      # Replay-cache TTL for DPoP `jti` values. Derived from the `iat`
      # acceptance window so a proof that is accepted once stays in the cache
      # for the full window it could be re-accepted in — there is no way to
      # widen the tolerance without widening the cache. The `+30` margin
      # covers Redis SETEX propagation latency and stays well below the
      # smallest realistic access-token TTL (15 minutes).
      def dpop_replay_ttl : Int32
        {dpop_iat_future_tolerance, dpop_iat_past_tolerance}.max + 30
      end
    end

    record MFAConfig,
      totp : TOTPConfig = TOTPConfig.new,
      enforcement : String = "preferred" do
      # Returns true when MFA is mandatory for every login. `preferred`
      # asks but never blocks; the login pipeline is the only consumer.
      def enforcement_always? : Bool
        enforcement == "always"
      end
    end

    record TOTPConfig,
      enabled : Bool = true,
      window : Int32 = 1,
      issuer : String = "Facet" do
      # Returns true when TOTP MFA is available on this instance. The login
      # gates read the effective policy (`IAM::Policy`), which translates
      # this file boolean into the `iam.mfa.type` setting — the record
      # accessor stays for the two config-side consumers (otpauth issuer,
      # window).
      def enabled? : Bool
        enabled
      end
    end

    # The authentication-mode record (`iam.auth`). The mode decides whether
    # password login stays available alongside federated login (`hybrid`)
    # or is removed entirely (`oidc_only`) — the login, password-reset, and
    # first-credential bootstrap routes refuse under `oidc_only` (see
    # `IAM::Policy`). The config path stays byte-identical to the
    # SystemSettings path so the runtime-settings fallback reads it
    # directly.
    record AuthConfig,
      mode : String = "hybrid"

    # The OIDC provisioning record (`iam.oidc`). `provision_roles` is the
    # instance-wide baseline role set for JIT-provisioned accounts — the
    # config-file tier of the `iam.oidc.provision_roles` system setting.
    # Entries are qualified `iam.Roles` references (`iam.Roles.employee`),
    # the same grammar the settings document stores. A provider document
    # with a `default_role` overrides the whole baseline for that provider.
    record OidcConfig,
      provision_roles : Array(String) = [] of String

    private def self.load_iam(raw : YAML::Any) : IAMConfig
      iam_raw = raw["iam"]?

      return IAMConfig.new if iam_raw.nil? || iam_raw.raw.nil?

      # Honor an explicit `secure_cookies: false`; a missing (or non-boolean)
      # key keeps the secure default. The previous `|| true` form collapsed
      # an explicit `false` into `true`, making the YAML key a lie for any
      # environment that must run on plain HTTP (docker e2e stacks).
      explicit_secure = iam_raw["secure_cookies"]?.try(&.as_bool?)

      IAMConfig.new(
        jwt: load_jwt(iam_raw),
        mfa: load_mfa(iam_raw),
        auth: load_auth(iam_raw),
        oidc: load_oidc(iam_raw),
        change_password_expiration: iam_raw["change_password_expiration"]?.try(&.as_i) || 86400,
        secure_cookies: explicit_secure != false,
      )
    end

    # Parses the auth-mode record of the iam config. The value is validated
    # at load time — fail closed like `enforcement`, so a typo can never
    # silently downgrade the mode (and `oidc_only` can never activate by
    # accident).
    private def self.load_auth(iam_raw : YAML::Any) : AuthConfig
      auth_raw = iam_raw["auth"]?
      return AuthConfig.new if auth_raw.nil? || auth_raw.raw.nil?

      mode = auth_raw["mode"]?.try(&.as_s) || "hybrid"
      unless mode == "hybrid" || mode == "oidc_only"
        raise ArgumentError.new(
          "iam.auth.mode must be 'hybrid' or 'oidc_only' (got '#{mode}')"
        )
      end

      AuthConfig.new(mode: mode)
    end

    # Parses the oidc provisioning section of the iam config. Entries must
    # be non-empty strings — a malformed baseline fails closed at boot like
    # the auth mode, so a typo can never silently disable provisioning.
    private def self.load_oidc(iam_raw : YAML::Any) : OidcConfig
      oidc_raw = iam_raw["oidc"]?
      return OidcConfig.new if oidc_raw.nil? || oidc_raw.raw.nil?

      roles_raw = oidc_raw["provision_roles"]?
      return OidcConfig.new if roles_raw.nil? || roles_raw.raw.nil?

      entries = roles_raw.as_a?.try(&.compact_map(&.as_s?)) || [] of String
      entries.each do |entry|
        if entry.strip.empty?
          raise ArgumentError.new(
            "iam.oidc.provision_roles entries must be non-empty iam.Roles references"
          )
        end
      end

      OidcConfig.new(provision_roles: entries)
    end

    # Parses the JWT section of the iam config.
    private def self.load_jwt(iam_raw : YAML::Any) : JWTConfig
      jwt_raw = iam_raw["jwt"]?
      return JWTConfig.new if jwt_raw.nil? || jwt_raw.raw.nil?

      JWTConfig.new(
        access_token_ttl: jwt_raw["access_token_ttl"]?.try(&.as_i) || 900,
        refresh_token_ttl: jwt_raw["refresh_token_ttl"]?.try(&.as_i) || 1_209_600,
        refresh_grace_window: jwt_raw["refresh_grace_window"]?.try(&.as_i) || 10,
        dpop_iat_future_tolerance: jwt_raw["dpop_iat_future_tolerance"]?.try(&.as_i) || 10,
        dpop_iat_past_tolerance: jwt_raw["dpop_iat_past_tolerance"]?.try(&.as_i) || 30,
      )
    end

    # Parses MFA/TOTP config from the iam section. The `enforcement` value
    # is validated at load time — a typo fails closed instead of silently
    # downgrading the enforcement mode.
    private def self.load_mfa(iam_raw : YAML::Any) : MFAConfig
      mfa_raw = iam_raw["mfa"]?
      return MFAConfig.new if mfa_raw.nil? || mfa_raw.raw.nil?

      enforcement = mfa_raw["enforcement"]?.try(&.as_s) || "preferred"
      unless enforcement == "preferred" || enforcement == "always"
        raise ArgumentError.new(
          "iam.mfa.enforcement must be 'preferred' or 'always' (got '#{enforcement}')"
        )
      end

      totp = MFAConfig.new.totp
      if (totp_raw = mfa_raw["totp"]?) && !totp_raw.raw.nil?
        # Same honesty rule as secure_cookies: only an explicit `false` may
        # disable TOTP. The previous `|| true` form ignored the key at load.
        explicit_enabled = totp_raw["enabled"]?.try(&.as_bool?)

        totp = TOTPConfig.new(
          enabled: explicit_enabled != false,
          window: totp_raw["window"]?.try(&.as_i) || 1,
          issuer: totp_raw["issuer"]?.try(&.as_s) || "Facet"
        )
      end

      MFAConfig.new(totp: totp, enforcement: enforcement)
    end
  end
end
