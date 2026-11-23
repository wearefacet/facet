# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "pg"
require "json"
require "../util/script_helpers"
require "../error"
require "../secrets/store"
require "./policy"
require "./roles"

module Facet
  module IAM
    # Handles the login flow: auth-mode gate → lockout check → password
    # verify → role resolve → MFA gate.
    module Login
      Log = ::Log.for("facet.iam.login")
      # Result of a login attempt.
      #
      # - `TokensEmitted(Result)` — password correct, MFA not needed; tokens are ready.
      # - `MFARequired(Challenge)` — password correct, but MFA challenge needed.
      # - `Error` — invalid credentials, lockout, etc.
      # - `PasswordChangeRequired` — password correct, but must be changed before proceeding.

      record PasswordChangeRequired,
        change_token : String

      record MFARequired,
        challenge_id : String

      record EnrollmentRequired,
        enroll_token : String,
        secret : String,
        otpauth_uri : String

      record TokensEmitted,
        result : TokenEmitter::Result

      # Maximum failed password attempts before lockout.
      MAX_PWD_ATTEMPTS = 10

      # Per-IP maximum failed password attempts before lockout.
      MAX_IP_ATTEMPTS = 20

      # Attempts to authenticate an account.
      #
      # * `db` — database connection
      # * `email` — the account's email (will be normalized — lowercased and stripped)
      # * `password` — the password to verify
      # * `cookie` — whether to set cookies (vs. returning tokens in body)
      # * `role` — optional explicit role to use; falls back to default_role or first assigned
      # * `ip` — client IP (for attempt counting)
      # * `user_agent` — client account agent (for session metadata)
      def self.call(
        db : DB::Connection,
        email : String,
        password : String,
        cookie : Bool = true,
        role : String? = nil,
        ip : String? = nil,
        user_agent : String? = nil,
      ) : TokensEmitted | MFARequired | EnrollmentRequired | PasswordChangeRequired | Facet::ServiceError
        # 0. Authentication mode. Under `oidc_only` the password path is a
        # server boundary, not a UI state: the route refuses before any
        # credential work (no bcrypt burn, no attempt counters), and the
        # refusal lands in the audit log. The browser sees the plain error
        # body — the machine-readable reason rides the flat `meta` key.
        if Policy.oidc_only?(db)
          # No account resolved — the subject is the synthetic
          # `system:password` principal, so the event keeps the `system`
          # actioner.
          Helpers.write_login_event(db, "system:password",
            "password_login_denied",
            "Password login refused under auth mode 'oidc_only' (email: #{normalized_email(email)})",
            subject_resolved: false)
          return Facet::ServiceError.new(403, "Password login is disabled",
            meta: {"reason" => "auth_mode"})
        end

        # 1. Normalize email and look up account
        normalized = email.strip.downcase
        account = Helpers.find_account_by_email(db, normalized)
        if account.nil?
          return Facet::ServiceError.new(401, "Invalid credentials")
        end

        account_id = account[:id]

        # 2. Pre-auth checks (lockout, account status, attempt thresholds)
        pre_result = pre_auth_checks(db, account_id, account[:status], account[:service_account], ip)
        return pre_result if pre_result.is_a?(Facet::ServiceError)

        # 3. Verify password against the `password` slot. `nil` (missing
        # slot) and `false` (mismatch) both take the invalid-credentials
        # path — the nil path burns a dummy bcrypt comparison, so an
        # unknown account and a wrong password cost the same time.
        doc_ref = "iam.Account.#{account_id}"
        verified = Secrets.verify(db, doc_ref, "password", password)
        unless verified
          attempts = LoginThrottle.increment_pwd_attempts(account_id)
          LoginThrottle.increment_ip_attempts(ip) if ip
          remaining = (MAX_PWD_ATTEMPTS - attempts).clamp(0, MAX_PWD_ATTEMPTS)
          # Only the lockout writes a LoginEvent row (B-138) — per-attempt
          # rows would flood the event log. This log line is the per-attempt
          # audit record: account, client IP, remaining attempts.
          Log.warn do
            from = ip ? ", ip=#{ip}" : ""
            "Failed password attempt (account_id=#{account_id}#{from}, remaining=#{remaining})"
          end
          return Facet::ServiceError.new(401, "Invalid credentials",
            meta: {"remaining_attempts" => remaining.to_s})
        end

        LoginThrottle.reset_pwd_attempts(account_id, ip)

        # 4. Check if password must be changed before proceeding. Issue a
        # one-shot token so the change-password route can authorize the
        # bootstrap without requiring a session.
        if account[:must_change_pw]
          token = PwdChangeToken.create_pwd_change_token(account_id, Policy.change_password_expiration(db))
          return PasswordChangeRequired.new(change_token: token)
        end

        # 5. Resolve and verify role
        role_result = resolve_and_verify_role(db, account[:roles], role, account[:default_role])
        return role_result if role_result.is_a?(Facet::ServiceError)
        resolved_role = role_result.as(String)

        # 6. MFA gate, or emit tokens
        finish_login(db, account, resolved_role, cookie, user_agent, ip)
      end

      # ── Private ──────────────────────────────────────────────────

      # Runs the MFA gate and, when no gate holds the login, emits tokens.
      #
      # Under `always` enforcement an un-enrolled account is held at the
      # enrollment step: `MFA.setup` stores the provisional secret, and
      # tokens are issued only after `Enroll.verify` confirms a code. That
      # branch sits before the challenge check — an un-enrolled account has
      # no secret to challenge against.
      private def self.finish_login(
        db : DB::Connection,
        account : NamedTuple(id: String, email: String, display_name: String, roles: Array(String), default_role: String?, status: String, service_account: Bool, must_change_pw: Bool, mfa_enabled: Bool),
        resolved_role : String,
        cookie : Bool,
        user_agent : String?,
        ip : String?,
      ) : TokensEmitted | MFARequired | EnrollmentRequired | Facet::ServiceError
        account_id = account[:id]

        if enroll_gate_active?(db, account[:mfa_enabled])
          # Reuse the pending secret a previous login already minted —
          # re-minting would invalidate the QR code the account already
          # received (B-300). Mint only when the slot is empty: a deliberate
          # reset (`MFA.disable`) clears it, so the next login starts fresh.
          setup = pending_setup(db, account_id, account[:email]) ||
                  MFA.setup(db, account_id, account[:email])
          return setup if setup.is_a?(Facet::ServiceError)

          enroll_token = EnrollToken.create_enroll_token(account_id, resolved_role, cookie)
          return EnrollmentRequired.new(
            enroll_token: enroll_token,
            secret: setup.secret,
            otpauth_uri: setup.otpauth_uri,
          )
        end

        if mfa_gate_active?(db, account[:mfa_enabled])
          challenge_id = create_mfa_challenge(account_id, resolved_role, cookie, user_agent, ip)
          return MFARequired.new(challenge_id: challenge_id)
        end

        # Any full login that issues tokens completes the bootstrap: the
        # status flip is idempotent (a no-op patch is a success), so it only
        # writes when the account is still `pending`.
        if account[:status] == "pending"
          AccountPatch.call(db, account_id, {"status" => JSON::Any.new("active")})
        end

        emit_result = emit_tokens(db, account_id, resolved_role, cookie, user_agent, ip)
        return emit_result if emit_result.is_a?(Facet::ServiceError)

        Helpers.write_login_event(db, account_id, "login", "Role: #{resolved_role}")
        TokensEmitted.new(result: emit_result)
      end

      # Reveals the pending enrollment secret an earlier login stored in the
      # sealed `mfa` slot. Returns `nil` when the slot is empty — no pending
      # enrollment, mint a fresh secret.
      private def self.pending_setup(
        db : DB::Connection,
        account_id : String,
        account_name : String,
      ) : MFA::SetupResult?
        secret = Secrets.reveal(db, "iam.Account.#{account_id}", "mfa")
        return nil if secret.nil?

        MFA::SetupResult.new(
          secret: secret,
          otpauth_uri: TOTP.otpauth_uri(secret, account_name, Config.mfa.totp.issuer),
        )
      end

      # Checks password attempt thresholds and returns an Error if exceeded.
      private def self.check_attempt_thresholds(db : DB::Connection, account_id : String, ip : String?) : Facet::ServiceError?
        pwd_count = LoginThrottle.get_pwd_attempts(account_id)
        if pwd_count >= MAX_PWD_ATTEMPTS
          LoginThrottle.set_lockout(account_id)
          Helpers.write_login_event(db, account_id, "lockout", "Password attempt limit reached")
          return Facet::ServiceError.new(429, "Too many attempts. Try again later.")
        end

        ip_count = ip ? LoginThrottle.get_ip_attempts(ip) : 0
        if ip_count >= MAX_IP_ATTEMPTS
          return Facet::ServiceError.new(429, "Too many attempts. Try again later.")
        end

        nil
      end

      # Checks lockout, account status, and attempt thresholds before password verification.
      # A service account cannot log in with email + password — it is a
      # machine identity that authenticates through API keys instead.
      private def self.pre_auth_checks(db : DB::Connection, account_id : String, status : String, service_account : Bool, ip : String?) : Facet::ServiceError?
        if LoginThrottle.locked_out?(account_id)
          return Facet::ServiceError.new(429, "Too many attempts. Try again later.")
        end

        # `pending` is password-login-only: an invited account may complete
        # its bootstrap through the login pipeline, but no app token or API
        # key liveness check accepts it.
        if status != "active" && status != "pending"
          return Facet::ServiceError.new(403, "Account is #{status}")
        end

        if service_account
          return Facet::ServiceError.new(403, "Service accounts cannot use password login")
        end

        check_attempt_thresholds(db, account_id, ip)
      end

      # Resolves the active role and verifies the role document exists.
      #
      # An explicit election the account does not hold is a hard refusal.
      # A roleless account with no explicit election runs under the anonymous
      # role instead (B-120) — it can authenticate, so it must be able to
      # connect; the frontend renders the no-role screen from the emitted
      # `available_roles` / `active_role` pair.
      private def self.resolve_and_verify_role(db : DB::Connection, assigned_roles : Array(String), explicit_role : String?, default_role : String?) : String | Facet::ServiceError
        resolved = resolve_role(assigned_roles, explicit_role, default_role)
        if resolved.nil?
          if explicit_role
            # Explicit election the account does not hold — keep the original
            # message split: no roles at all vs. a role the account lacks.
            if assigned_roles.empty?
              return Facet::ServiceError.new(403, "No role assigned")
            end
            return Facet::ServiceError.new(403, "Role '#{explicit_role}' is not assigned to this account")
          end
          resolved = ANONYMOUS_ROLE_ID
        end

        role_doc = Helpers.find_role_content(db, resolved)
        return Facet::ServiceError.new(403, "Role not found or disabled") if role_doc.nil?

        resolved
      end

      # Returns true if MFA is applicable for the current auth context.
      # `mfa_enabled` is the account document field — the single source of
      # truth (nothing reads MFA state from the secret store). The factor
      # type comes from the effective policy (`IAM::Policy`): `none` never
      # challenges — enrolled accounts keep their factor data, and
      # re-enabling the type reactivates it on the next login.
      private def self.mfa_gate_active?(db : DB::Connection, mfa_enabled : Bool) : Bool
        Policy.mfa_type(db) == "totp" && mfa_enabled
      end

      # Returns true when the login must be held at the enrollment step.
      # The predicate lives on `IAM::Policy` — the first-credential bootstrap
      # (the invite-link confirm) reads the same gate (B-141).
      private def self.enroll_gate_active?(db : DB::Connection, mfa_enabled : Bool) : Bool
        Policy.enroll_hold?(db, mfa_enabled)
      end

      # The audit form of a submitted email: lowercased, stripped, and
      # bounded so a hostile body cannot flood the details field.
      private def self.normalized_email(email : String) : String
        value = email.strip.downcase
        value = value[0, 254] if value.size > 254
        value
      end

      # Resolves the active role: explicit → default_role → first assigned.
      private def self.resolve_role(assigned_roles : Array(String), explicit : String?, default_role : String? = nil) : String?
        if explicit
          return explicit if assigned_roles.includes?(explicit)
          return nil
        end

        if default_role && assigned_roles.includes?(default_role)
          return default_role
        end

        assigned_roles.first?
      end

      # Creates an MFA challenge in Redis.
      private def self.create_mfa_challenge(
        account_id : String,
        active_role : String,
        cookie_requested : Bool,
        user_agent : String?,
        ip : String?,
      ) : String
        challenge_id = Util::ScriptHelpers.ulid
        r = RedisSession.redis
        r.hset(
          "challenge:#{challenge_id}",
          "account_id", account_id,
          "active_role", active_role,
          "type", "totp",
          "cookie_requested", cookie_requested.to_s,
          "attempts_remaining", "5",
          "user_agent", user_agent || "",
          "ip", ip || "",
        )
        r.expire("challenge:#{challenge_id}", 300)
        challenge_id
      end

      # Emits tokens after successful authentication (no MFA needed).
      private def self.emit_tokens(
        db : DB::Connection,
        account_id : String,
        active_role : String,
        cookie : Bool,
        user_agent : String?,
        ip : String?,
      ) : TokenEmitter::Result | Facet::ServiceError
        SessionEmit.call(db, account_id, active_role, cookie, user_agent: user_agent, ip: ip)
      end
    end
  end
end
