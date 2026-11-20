# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "pg"
require "../system_settings"

module Facet
  module IAM
    # The single read point over the effective security policy — the MFA
    # and authentication-mode settings (`iam.mfa.type`,
    # `iam.mfa.enforcement`, `iam.auth.mode` on `core.SystemSettings`) and
    # the credential-token TTL (`iam.change_password_expiration`).
    #
    # Every consumer (the login gates, the MFA setup gate, the two
    # `mfa_enforcement` response sites, the password-reset and
    # first-credential refusals) reads through here instead of
    # `Config.instance.iam.*`. The reads go through
    # `SystemSettings.uncached_string_at` — the document row directly,
    # never the process settings cache: an auth decision must not tolerate
    # a stale-cache window. The fanout is the fast path for the rest of
    # the settings surface, but it is not a freshness guarantee this gate
    # may lean on — a CLI writer publishes only since `CLI.dispatch`
    # flushes the publisher, and a re-applied value produces no mutation
    # at all (the empty-diff fast path in `Document::Update`), so nothing
    # fans out. One primary-key read per call; the gates sit on non-hot
    # paths (login, password reset, `/me`). This mirrors the CLI posture
    # of the role content cache, which also bypasses its process cache.
    # The runtime settings document pins the value when set, the config
    # file is the fallback tier, and a settings save takes effect on the
    # next read without a restart.
    #
    # The `|| default` chains below are defensive only — every path's file
    # fallback always yields a value (`totp.enabled` is a non-optional
    # Bool; the other two paths have non-optional file strings), so the
    # effective read never returns nil. The constants keep the grammar in
    # one place for the write gate and the CLI to mirror.
    #
    # Existing sessions survive a policy flip; they authenticated before
    # it. The OIDC login path never consults the local MFA policy — the
    # IdP is the factor of record.
    module Policy
      MFA_TYPES       = %w[none totp]
      MFA_ENFORCEMENT = %w[preferred always]
      AUTH_MODES      = %w[hybrid oidc_only]

      # The effective MFA factor type: `"none"` (MFA off — no challenge, no
      # enroll hold; enrolled accounts keep their factor data and
      # re-enabling the type reactivates it) or `"totp"`. Uncached — see
      # the module comment.
      def self.mfa_type(db : DB::Connection) : String
        SystemSettings.uncached_string_at(db, "iam.mfa.type") || "totp"
      end

      # The effective MFA enforcement: `"preferred"` asks but never blocks;
      # `"always"` holds every un-enrolled login at the enrollment step.
      # Uncached — see the module comment.
      def self.mfa_enforcement(db : DB::Connection) : String
        SystemSettings.uncached_string_at(db, "iam.mfa.enforcement") || "preferred"
      end

      # True when an authentication must stop at the enrollment step: the
      # factor type is `totp`, enforcement is `always`, and the account is
      # not enrolled yet. One predicate for every hold site — the login gate
      # and the first-credential bootstrap (B-141) hold the same way.
      def self.enroll_hold?(db : DB::Connection, mfa_enabled : Bool) : Bool
        mfa_type(db) == "totp" && mfa_enforcement(db) == "always" && !mfa_enabled
      end

      # The effective authentication mode: `"hybrid"` allows password and
      # federated login; `"oidc_only"` removes the password path (login,
      # password reset, and first-credential bootstrap refuse). Uncached —
      # see the module comment.
      def self.auth_mode(db : DB::Connection) : String
        SystemSettings.uncached_string_at(db, "iam.auth.mode") || "hybrid"
      end

      # True when password authentication is refused outright.
      def self.oidc_only?(db : DB::Connection) : Bool
        auth_mode(db) == "oidc_only"
      end

      # The effective credential-token TTL in seconds: the lifetime of the
      # `reset`-slot link tokens (password reset, invite link) and of the
      # first-credential change token. Every issuing site reads through
      # this one method — no call site re-derives the precedence. Uncached
      # — see the module comment. A token minted before a save keeps the
      # expiry it was minted with; the new window applies from the next
      # mint.
      def self.change_password_expiration(db : DB::Connection) : Int32
        SystemSettings.uncached_int_at(db, "iam.change_password_expiration")
          .try(&.to_i32) || Config.change_password_expiration
      end

      # The instance-wide JIT-provisioning baseline: the roles every
      # OIDC-provisioned account receives when its provider document sets
      # no `default_role`. Uncached — see the module comment: the roles a
      # new account starts with are a security decision, and a save must
      # apply at the next provisioning without a stale-cache window.
      # Returns the stored list verbatim (qualified `iam.Roles`
      # references); an empty list means no instance baseline.
      def self.provision_roles(db : DB::Connection) : Array(String)
        SystemSettings.uncached_string_array_at(db, "iam.oidc.provision_roles")
      end
    end
  end
end
