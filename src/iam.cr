# SPDX-License-Identifier: BUSL-1.1
# Copyright (c) 2026 Amplitude Solutions Ltd

require "./iam/helpers"
require "./iam/redis"
require "./iam/config"
require "./iam/policy"
require "./iam/auth_state"
require "./iam/account_patch"
require "./iam/backup_codes"
require "./iam/invite"
require "./iam/api_key"
require "./iam/totp"
require "./iam/jwt"
require "./iam/redis_session"
require "./iam/login_throttle"
require "./iam/pwd_change_token"
require "./iam/enroll_token"
require "./iam/token_emitter"
require "./iam/roles"
require "./iam/session_emit"
require "./iam/login"
require "./iam/challenge"
require "./iam/refresh"
require "./iam/logout"
require "./iam/mfa"
require "./iam/enroll"
require "./iam/password_reset"
require "./iam/app_launcher"
require "./iam/routes"
require "./iam/seed"
require "./iam/seed_cli"
require "./iam/account_cli"

module Facet
  # Namespace for Identity and Access Management.
  #
  # Handles authentication (password, TOTP MFA), session management via
  # Redis, and issues stateless ES256 JWT access tokens.
  #
  # ## Storage split
  #
  # - **Redis**: sessions, MFA challenges, login lockout counters.
  # - **`secrets` table** (via `Facet::Secrets`): password hashes, MFA
  #   secrets, reset tokens — keyed by account document + slot, never
  #   event-sourced. Volatile per-account state (TOTP step counter) lives
  #   in the `auth_state` table.
  # - **Doctypes**: `iam.Account` (user profile, roles, `mfa_enabled`,
  #   `must_change_pw`), `iam.LoginEvent` (audit).
  module IAM
    Log = ::Log.for("facet.iam")
  end
end
