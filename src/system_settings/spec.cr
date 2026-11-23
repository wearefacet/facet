# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "json"

module Facet
  # Runtime settings — the hot-changeable platform configuration.
  #
  # One singleton system document (`core.SystemSettings`, id `settings`)
  # whose content mirrors the assistant, mail, artifact, and retention
  # sections of the config file. A non-null document field pins the value;
  # an explicit null means "follow the file". The read side merges
  # document-over-file through the registry below; see
  # `doc/backend/system-settings.md`.
  module SystemSettings
    # Value kind accepted for a registered path. This module's own enum —
    # the account-settings enum (`Settings::Keys::Kind`) has no number,
    # text, or secret kind.
    enum Kind
      String
      Number
      Bool
      Text
      Secret
      StringList
    end

    # One registered config path. The path is the identity everywhere —
    # config file, settings document, registry, read API, and fallback
    # resolution share one dot-separated string; no conversion exists.
    #
    # The `fallback` proc reads the file side at the same path. The config
    # struct applies its own defaults, so the proc gives the built-in third
    # tier of the resolution order (document → file → default) for free.
    # One deliberate exception: `iam.mfa.type` translates the file's
    # `iam.mfa.totp.enabled` boolean (the historical key) into the policy
    # grammar — its fallback reads a *different* path than its own, so the
    # "fallback reads the file side at the same path" invariant does not
    # hold for that one entry.
    #
    # There is deliberately no consumer tag on the entry: hot-reload
    # invalidation is per-cache, not per-path — every settings mutation
    # marks the process cache stale and re-arms every rebuild hook (the
    # mail adapter re-arm; the assistant resolves at turn start with no
    # hook of its own). A per-path tag would be metadata nothing reads.
    record Spec,
      path : String,
      kind : Kind,
      secret : Bool,
      fallback : Proc(Facet::Config, JSON::Any?) do
      # Secret paths never enter the process cache and never ride any read
      # API response; their values resolve through `reveal_secret` only.
      def secret? : Bool
        secret
      end
    end

    # ── JSON::Any builders for the fallback procs ──────────────────────

    private def self.s(v : String?) : JSON::Any?
      v ? JSON::Any.new(v) : nil
    end

    private def self.i(v : Int32?) : JSON::Any?
      v ? JSON::Any.new(v.to_i64) : nil
    end

    private def self.f(v : Float64?) : JSON::Any?
      v ? JSON::Any.new(v) : nil
    end

    private def self.b(v : Bool) : JSON::Any?
      JSON::Any.new(v)
    end

    private def self.sl(v : Array(String)) : JSON::Any
      JSON::Any.new(v.map { |s| JSON::Any.new(s) })
    end

    # The registered set of config paths. Secret paths carry the same
    # fallback (the file's `!env`-expanded credential) for the reveal-time
    # resolution order, but their values never enter the process cache.
    SPEC = {
      # The one display name every assistant surface shows. The file struct
      # carries the built-in default ("Assistant"), so this path always
      # resolves to a value — `SystemSettings::AssistantView.display_name`
      # serves it on `/Api/iam/me` and the platform settings page pins it.
      "assistant.name" => Spec.new(
        path: "assistant.name", kind: Kind::String, secret: false,
        fallback: ->(c : Facet::Config) : JSON::Any? { s(c.assistant.name) },
      ),
      "assistant.api_endpoint" => Spec.new(
        path: "assistant.api_endpoint", kind: Kind::String, secret: false,
        fallback: ->(c : Facet::Config) : JSON::Any? { s(c.assistant.api_endpoint) },
      ),
      "assistant.api_key" => Spec.new(
        path: "assistant.api_key", kind: Kind::Secret, secret: true,
        fallback: ->(c : Facet::Config) : JSON::Any? { s(c.assistant.api_key) },
      ),
      "assistant.model" => Spec.new(
        path: "assistant.model", kind: Kind::String, secret: false,
        fallback: ->(c : Facet::Config) : JSON::Any? { s(c.assistant.model) },
      ),
      "assistant.system_prompt" => Spec.new(
        path: "assistant.system_prompt", kind: Kind::Text, secret: false,
        fallback: ->(c : Facet::Config) : JSON::Any? { s(c.assistant.system_prompt) },
      ),
      "assistant.max_tokens" => Spec.new(
        path: "assistant.max_tokens", kind: Kind::Number, secret: false,
        fallback: ->(c : Facet::Config) : JSON::Any? { i(c.assistant.max_tokens) },
      ),
      "assistant.temperature" => Spec.new(
        path: "assistant.temperature", kind: Kind::Number, secret: false,
        fallback: ->(c : Facet::Config) : JSON::Any? { f(c.assistant.temperature) },
      ),
      "assistant.max_history" => Spec.new(
        path: "assistant.max_history", kind: Kind::Number, secret: false,
        fallback: ->(c : Facet::Config) : JSON::Any? { i(c.assistant.max_history) },
      ),
      "assistant.auto_execute_tools" => Spec.new(
        path: "assistant.auto_execute_tools", kind: Kind::Bool, secret: false,
        fallback: ->(c : Facet::Config) : JSON::Any? { b(c.assistant.auto_execute_tools?) },
      ),
      "mail.adapter" => Spec.new(
        path: "mail.adapter", kind: Kind::String, secret: false,
        fallback: ->(c : Facet::Config) : JSON::Any? { s(c.mail.adapter) },
      ),
      "mail.from_address" => Spec.new(
        path: "mail.from_address", kind: Kind::String, secret: false,
        fallback: ->(c : Facet::Config) : JSON::Any? { s(c.mail.from_address) },
      ),
      "mail.from_name" => Spec.new(
        path: "mail.from_name", kind: Kind::String, secret: false,
        fallback: ->(c : Facet::Config) : JSON::Any? { s(c.mail.from_name) },
      ),
      "mail.smtp.host" => Spec.new(
        path: "mail.smtp.host", kind: Kind::String, secret: false,
        fallback: ->(c : Facet::Config) : JSON::Any? { s(c.mail.smtp.host) },
      ),
      "mail.smtp.port" => Spec.new(
        path: "mail.smtp.port", kind: Kind::Number, secret: false,
        fallback: ->(c : Facet::Config) : JSON::Any? { i(c.mail.smtp.port) },
      ),
      "mail.smtp.username" => Spec.new(
        path: "mail.smtp.username", kind: Kind::String, secret: false,
        fallback: ->(c : Facet::Config) : JSON::Any? { s(c.mail.smtp.username) },
      ),
      "mail.smtp.password" => Spec.new(
        path: "mail.smtp.password", kind: Kind::Secret, secret: true,
        fallback: ->(c : Facet::Config) : JSON::Any? { s(c.mail.smtp.password) },
      ),
      "mail.smtp.use_tls" => Spec.new(
        path: "mail.smtp.use_tls", kind: Kind::Bool, secret: false,
        fallback: ->(c : Facet::Config) : JSON::Any? { b(c.mail.smtp.use_tls) },
      ),
      "artifact.grant_prune_days" => Spec.new(
        path: "artifact.grant_prune_days", kind: Kind::Number, secret: false,
        fallback: ->(c : Facet::Config) : JSON::Any? { i(c.artifact.grant_prune_days) },
      ),
      "artifact.grant_ttl_seconds" => Spec.new(
        path: "artifact.grant_ttl_seconds", kind: Kind::Number, secret: false,
        fallback: ->(c : Facet::Config) : JSON::Any? { i(c.artifact.grant_ttl_seconds) },
      ),
      "artifact.grant_ttl_media_seconds" => Spec.new(
        path: "artifact.grant_ttl_media_seconds", kind: Kind::Number, secret: false,
        fallback: ->(c : Facet::Config) : JSON::Any? { i(c.artifact.grant_ttl_media_seconds) },
      ),
      "artifact.prune_after_days" => Spec.new(
        path: "artifact.prune_after_days", kind: Kind::Number, secret: false,
        fallback: ->(c : Facet::Config) : JSON::Any? { i(c.artifact.prune_after_days) },
      ),
      # Read visibility only: the storage adapter wires once per process
      # from the config file, and every artifact row lives under the one
      # constant storage key — a runtime switch would strand the existing
      # bytes in the old backend. The doctype definition has no such field
      # and the write gate refuses any value that reaches it, so the pin
      # can never exist; the fallback keeps the GET surface showing the
      # effective adapter.
      "artifact.storage.type" => Spec.new(
        path: "artifact.storage.type", kind: Kind::String, secret: false,
        fallback: ->(c : Facet::Config) : JSON::Any? { s(c.artifact.storage.type) },
      ),
      "mutations.retention_days" => Spec.new(
        path: "mutations.retention_days", kind: Kind::Number, secret: false,
        fallback: ->(c : Facet::Config) : JSON::Any? { i(c.mutations.retention_days) },
      ),
      "tombstone.content_retention_days" => Spec.new(
        path: "tombstone.content_retention_days", kind: Kind::Number, secret: false,
        fallback: ->(c : Facet::Config) : JSON::Any? { i(c.tombstone.content_retention_days) },
      ),
      # ── Localization ──────────────────────────────────────────────────
      #
      # The instance defaults an account follows when it has not set its
      # own timezone or language. Consumers: the account-settings default
      # chain (`Settings::Service.default_for`) and the personal settings
      # page's "Server default" option.
      "localization.default_timezone" => Spec.new(
        path: "localization.default_timezone", kind: Kind::String, secret: false,
        fallback: ->(c : Facet::Config) : JSON::Any? { s(c.localization.default_timezone) },
      ),
      "localization.default_language" => Spec.new(
        path: "localization.default_language", kind: Kind::String, secret: false,
        fallback: ->(c : Facet::Config) : JSON::Any? { s(c.localization.default_language) },
      ),
      # ── IAM policy ────────────────────────────────────────────────────
      #
      # The MFA and authentication-mode policy, and the credential-token
      # TTL. Consumers read through `IAM::Policy` (`src/iam/policy.cr`),
      # the single read point over the effective values.
      #
      # `iam.mfa.type` is the one path whose fallback reads a different
      # file path (`iam.mfa.totp.enabled`) and translates it: true → `totp`,
      # false → `none`. Its built-in default (`totp`) is unreachable —
      # `totp.enabled` is a non-optional Bool, so the file tier always
      # yields a value; the default is kept for completeness. The TOTP
      # parameters (`window`, `issuer`) stay file-only — implementation
      # knobs, not policy.
      "iam.mfa.type" => Spec.new(
        path: "iam.mfa.type", kind: Kind::String, secret: false,
        fallback: ->(c : Facet::Config) : JSON::Any? { s(c.iam.mfa.totp.enabled? ? "totp" : "none") },
      ),
      "iam.mfa.enforcement" => Spec.new(
        path: "iam.mfa.enforcement", kind: Kind::String, secret: false,
        fallback: ->(c : Facet::Config) : JSON::Any? { s(c.iam.mfa.enforcement) },
      ),
      "iam.auth.mode" => Spec.new(
        path: "iam.auth.mode", kind: Kind::String, secret: false,
        fallback: ->(c : Facet::Config) : JSON::Any? { s(c.iam.auth.mode) },
      ),
      # The credential-token TTL in seconds: the lifetime of the
      # `reset`-slot link tokens (password reset, invite link) and of the
      # first-credential change token. The file struct carries the
      # built-in default (86400), so the fallback always yields a value.
      "iam.change_password_expiration" => Spec.new(
        path: "iam.change_password_expiration", kind: Kind::Number, secret: false,
        fallback: ->(c : Facet::Config) : JSON::Any? { i(c.iam.change_password_expiration) },
      ),
      # The instance-wide JIT-provisioning baseline: the roles every
      # OIDC-provisioned account receives when its provider document sets
      # no `default_role`. Entries are qualified `iam.Roles` references —
      # the same form the account `roles` array stores. An empty array is
      # a valid value (no instance baseline; providers must carry their own
      # default_role). The write gate checks every entry against the live
      # `iam.Roles` rows; see `WriteGate.validate_provision_roles`.
      "iam.oidc.provision_roles" => Spec.new(
        path: "iam.oidc.provision_roles", kind: Kind::StringList, secret: false,
        fallback: ->(c : Facet::Config) : JSON::Any? { sl(c.iam.oidc.provision_roles) },
      ),
    } of String => Spec
  end
end
