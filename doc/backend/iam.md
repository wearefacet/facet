# IAM — Identity and Access Management

## Terminology

- **Account** — the identity. One account per person or machine (service account). Sessions, tokens, roles, and MFA belong to the account. Stored as `iam.Account` documents.
- **User** — the human being. Use only to qualify the person: "user-facing", "end user", "the user clicks". Do not name code after the person when the code holds an account.
- **Email** — the account's login identifier. The login request field is `email`; response payloads expose it as `email` inside the `account` object.
- **Credential** — a secret the account holds: the `password`, `mfa`, and `reset` slots in the secret store.
- Fixed external names keep their standard spelling: HTTP `User-Agent`, OIDC `userinfo` and `preferred_username`, JWT `sub`, and the LLM chat role `user`.

The IAM subsystem handles authentication (password + MFA), federated login through inbound OIDC (see [`oidc.md`](oidc.md)), account credential bootstrap (temporary passwords and invite links), session management via Redis, and issues stateless ES256 JWT access tokens. It provides the login/logout/refresh/challenge flows, MFA enrollment, and token emission.

## Source Files

| File | Role |
|---|---|
| `src/iam.cr` | Namespace root — loads all modules, declares `Facet::IAM::Log` |
| `src/iam/config.cr` | `Facet::IAM::Config` — delegates to `Facet::Config.instance.iam` |
| `src/iam/auth_state.cr` | `AuthState` — volatile operational state (`auth_state` table): atomic TOTP step guard |
| `src/iam/backup_codes.cr` | `BackupCodes` — single-use MFA backup codes (`mfa_backup_codes` table): digest-only storage, atomic single-use consume |
| `src/iam/account_patch.cr` | `AccountPatch` — flips account document fields with the system principal |
| `src/iam/helpers.cr` | `Helpers` — account finders (`find_account_by_email`, `find_account_by_id`; one shared row reader behind both), role content, permission manifests (role manifest + effective manifest for app-scoped callers), link validity phrase (`link_validity_text`), JWT claim helpers, login-event writers |
| `src/iam/api_key.cr` | `ApiKey` — static bearer keys (`fct_…`): token generation, SHA-256-only storage, per-request verification with pair liveness checks, list/revoke. Rows with `app_id` set are app-owned keys (backend apps) — see [`app-system.md`](app-system.md#backend-apps-—-service-account-+-api-key) |
| `src/iam/jwt.cr` | `JWT` — ES256 JWT sign/verify with algorithm pinning |
| `src/iam/redis_session.cr` | `RedisSession` — Redis session create/load/rotate/delete, app sessions, per-app listing and revocation |
| `src/iam/login_throttle.cr` | `LoginThrottle` — login lockout flag and brute-force attempt counters (password, per-IP, MFA verify) |
| `src/iam/pwd_change_token.cr` | `PwdChangeToken` — one-shot password-change bootstrap tokens (`pwd_change:{token}`) |
| `src/iam/enroll_token.cr` | `EnrollToken` — one-shot enroll-at-login tokens (`enroll:{token}`) |
| `src/iam/token_emitter.cr` | `TokenEmitter` — builds Result record, response bodies, HttpOnly cookies |
| `src/iam/policy.cr` | `Policy` — the single read point over the effective security policy (`mfa_type`, `mfa_enforcement`, `auth_mode`, `oidc_only?`): the runtime settings (`iam.mfa.type`, `iam.mfa.enforcement`, `iam.auth.mode` on `core.SystemSettings`) with the config file as the fallback tier. The reads bypass the process settings cache (`SystemSettings.uncached_string_at`) — an auth decision never serves a stale value |
| `src/iam/auth_mode_cli.cr` | `AuthModeCLI` — the `facet auth:mode {hybrid\|oidc_only}` recovery command; patches the SystemSettings document with the system principal (write gate included). `CLI.dispatch` publishes the command's buffered fanout after the run, so running servers drop their cached policy at once |
| `src/iam/login.cr` | `Login` — login flow: auth-mode gate → lockout check → password verify → role resolve → password-change gate → MFA gate → emit tokens. Under `oidc_only` the route refuses with `403` + a `password_login_denied` LoginEvent before any credential work |
| `src/iam/challenge.cr` | `Challenge` — MFA challenge verification, replay protection, attempt counting |
| `src/iam/enroll.cr` | `Enroll` — enroll-at-login verify: first TOTP code → `mfa_enabled` flip → session emission |
| `src/iam/session_emit.cr` | `SessionEmit` — shared token-emission step for every path that authenticates without a session (login, challenge, enroll, OIDC) |
| `src/iam/invite.cr` | `Invite` — credential bootstrap: temporary password, invite link, credential-states read |
| `src/iam/refresh.cr` | `Refresh` — token rotation with reuse detection (stale/grace/valid) |
| `src/iam/logout.cr` | `Logout` — session deletion + logout event |
| `src/iam/password_reset.cr` | `PasswordReset` — request (anti-enumeration + email) + confirm (single-use `reset`-slot token; first-credential bootstrap with auto-login) |
| `src/iam/app_launcher.cr` | `AppLauncher` — dashboard launcher: lists `app.App` registrations the active role may see (active, not marked `no_launcher`), each flagged `usable` (grant-satisfiable) |
| `src/iam/mfa.cr` | `MFA` — TOTP setup (provisional secret), verify (enable), disable (admin recovery) |
| `src/iam/totp.cr` | `TOTP` — RFC 6238 / RFC 4226 implementation, HMAC-SHA1, base32 encode/decode |
| `src/iam/routes.cr` | `Routes` — HTTP route registration under `/Api/iam`. `register` holds only the route declarations, grouped into `register_*` methods; each block calls one `handle_*` private method that holds the endpoint body. The RBAC gate for the operator routes is `authorize` — it writes the 403 and returns `nil` on refusal, so a route body calls it as `authorize(env, action, target) \|\| return` |
| `src/iam/seed.cr` | `Seed` — first-admin bootstrap (`seed_admin`) and dev-admin seed (`seed_dev_admin`) with the production refusal predicate |
| `src/iam/seed_cli.cr` | `SeedCLI` — CLI runner for `facet seed:admin`: email from argument or `SEED_ADMIN_EMAIL`, prints the one-time password once |
| `src/iam/account_cli.cr` | `AccountCLI` — CLI subcommands to list accounts/roles, create an account with a one-time password (the `temporary-password` bootstrap), and assign a role to an account |
| `src/emails/base_email.cr` | `BaseEmail` — Carbon email base class, adapter wiring from `mail:` config |
| `src/emails/password_reset_email.cr` | `PasswordResetEmail` — reset-link email with text + HTML templates |
| `src/emails/invite_email.cr` | `InviteEmail` — invite-link email with text + HTML templates |

## Storage Split

Five storage backends, each with a different security and durability profile:

| Backend | What | Why |
|---|---|---|
| **PostgreSQL** (`projections`) | `iam.Account` documents (profile, roles, `mfa_enabled`, `must_change_pw`), `iam.Roles` documents, `iam.LoginEvent` audit trail | Event-sourced, immutable, long-lived |
| **PostgreSQL** (`secrets`, via `Facet::Secrets` — see [`secrets.md`](secrets.md)) | Account secret slots: `password` (bcrypt `hash`), `mfa` (TOTP seed, AES-256-GCM `sealed`), `reset` (single-use link token, `token` mode with TTL — used by the password-reset flow and the invite link) | Never enters the event log — secret material must not be replayable; the seed is encrypted at rest; a token row holds only its SHA-256 digest |
| **PostgreSQL** (`auth_state`) | TOTP step counter (replay guard) | Volatile operational state — not a secret, not document data, no audit value |
| **PostgreSQL** (`api_keys`) | Static API keys: SHA-256 hash of the full token, display prefix, `{account, role}` pair, expiry, `last_used_at`, soft revoke, and the nullable `app_id` tag (set on app-owned keys issued for backend apps' service accounts — part of migration `0010_api_keys.sql`) | Never enters the event log — same secret-storage precedent as the `secrets` store (migration `0011_secrets.sql`) |
| **PostgreSQL** (`mfa_backup_codes`) | Single-use MFA backup codes: one row per code, SHA-256 digest of the normalized code, `used_at` marks consumption (migration `0011_secrets.sql`) | Never enters the event log — the same secret-storage precedent as `api_keys`; consumption is one atomic UPDATE that only matches rows still unused |
| **Redis** | Sessions, MFA challenges, lockout flags, attempt counters, password-change bootstrap tokens, OIDC flow state | Volatile, low-latency; full loss only forces re-login |

**Convergence rule:** every successful password write clears the `reset` slot in the same transaction (`Secrets.clear`). A slot write never touches another slot, so the clear is explicit. This makes a stale reset link die the moment its account gains a new credential.

## Seed Doctypes

All three are seeded by the core seeding process and documented in [`doc/backend/doctype-system.md`](doctype-system.md).

| Doctype | Seed Directory | Purpose |
|---|---|---|
| `iam.Account` | `data/seeds/iam.Account/` | Account — email, name, status, roles, default_role, organizational_unit (folder-like path used by RBAC scope predicates), service_account (machine identity — cannot log in with email + password), mfa_enabled, must_change_pw, federated_identities (OIDC links — see [`oidc.md`](oidc.md)). **The document id is the lowercased email address** (derived in `Document::Create.resolve_doc_id`; the create hook lowercases the stored email to match, and the update gate refuses an email change — see [`workflow.md`](workflow.md) → Qualified reference storage contract). `status` is `pending`, `active`, `suspended`, or `disabled`; `pending` marks an invited account that has not completed its bootstrap yet — it may log in with its first credential, and that login flips it to `active`. A create that supplies `status: active` for a human account stores `pending` (the bootstrap rule in the seed script; service accounts and JIT-provisioned OIDC accounts are exempt, and an explicit `suspended` / `disabled` is honoured) |
| `iam.Roles` | `data/seeds/iam.Roles/` | Named role with permission manifest — ships with admin (level 100), editor (30), viewer (20), comment_author (20), attachment_owner (20), and `anonymous` (0; the role served to unauthenticated API requests — see [`rbac.md`](rbac.md) → HTTP integration). `level` is a required integer field (0–100, no default) — every role create carries an explicit level, and `RBAC::RoleAuthority` gates every account-assignment and role-authoring write on it (see [`rbac.md`](rbac.md) → Role authority) |
| `iam.LoginEvent` | `data/seeds/iam.LoginEvent/` | Append-only audit log for auth events (login, logout, refresh, refresh_reuse, refresh_failed, app_refresh, mcp_refresh, lockout, password_reset_requested, password_reset_used, invite_accepted, password_change, temp_password_generated, invite_sent, mfa_enrolled, mfa_enabled, mfa_disabled, consent_granted, layer1_denied, api_key_created, api_key_revoked, session_revoked, app_sessions_revoked, oidc_login, oidc_provisioned, oidc_denied, password_login_denied). Phase 6 added an `app` field carrying the `app.App` projection id when the event concerns an app session; empty for ordinary browser-session events. See [`app-system.md`](app-system.md#audit-and-observability-phase-6). |

`data/seeds/iam.Account/script.lua` defines `create` and `update` lifecycle hooks that deduplicate the account's `roles` reference array, preserving first-occurrence order. The persisted array must contain no duplicate role ids — a duplicate would crash the frontend's keyed `{#each}` that renders the assignments page. Enforcement is server-side at the write boundary; the frontend additionally deduplicates defensively on load and on write.

The same hooks normalize the account's `organizational_unit` path. The invariant is "begins with `/` and ends with exactly one `/`" — only the boundaries are normalized (the inner path is left untouched, `a//b` stays `a//b`); an empty string collapses to the root `/`. A non-string value is rejected at write time (the doctype string-type validator is the primary gate; the hook is defence in depth). The RBAC scope machinery reads this field at request time (trusted bypass, see [`rbac.md`](rbac.md)) to resolve the `$organizational_unit` scope token.

## Public API

### `Facet::IAM::Login`

The login endpoint orchestrates the full authentication pipeline.

```crystal
result = Login.call(db, email: "user@example.com", password: "s3cret", cookie: false)
case result
in Login::TokensEmitted        # password correct, MFA not needed
in Login::MFARequired          # password correct, MFA challenge required
in Login::EnrollmentRequired   # password correct, un-enrolled under `always` enforcement
in Login::PasswordChangeRequired # password correct, but must_change_pw is set
in Facet::ServiceError         # invalid credentials, lockout, etc.
end
```

| Parameter | Type | Default | Description |
|---|---|---|---|
| `email` | `String` | — | Email address (normalized: stripped + lowercased) |
| `password` | `String` | — | Raw password |
| `cookie` | `Bool` | `true` | Whether to set HttpOnly cookies (vs. returning tokens in JSON body) |
| `role` | `String?` | `nil` | Explicit role override — a qualified role id (`iam.Roles.{name}`) |
| `ip` | `String?` | `nil` | Client IP (for attempt counting) |
| `user_agent` | `String?` | `nil` | User-Agent header (for session metadata) |

**Return types:**

- `Login::TokensEmitted(result : TokenEmitter::Result)` — authentication succeeded, tokens ready.
- `Login::MFARequired(challenge_id : String)` — password correct, frontend must complete MFA challenge.
- `Login::EnrollmentRequired(enroll_token, secret, otpauth_uri, mfa_enforcement)` — password correct, MFA enforcement is `always`, and the account is not enrolled yet. The response carries a one-shot enroll token plus the provisional TOTP secret and its `otpauth://` URI (the user cannot scan a QR that does not exist). The frontend completes the flow via `POST /Api/iam/mfa/enroll/verify`.
- `Login::PasswordChangeRequired(change_token : String)` — password correct, but `must_change_pw` is set; the one-shot `change_token` authorizes the bootstrap password change via `POST /Api/iam/change-password`.
- `Facet::ServiceError` — failure with HTTP status and message.

**Pipeline** (in order):
1. Email normalization (strip + downcase)
2. `IAM::Helpers.find_account_by_email` — query `projections` for `iam.Account`
3. `pre_auth_checks` — lockout check (`LoginThrottle.locked_out?`), account status check, attempt thresholds
4. Password verification via `Secrets.verify(db, "iam.Account.#{account_id}", "password", …)` — `nil` (missing slot) and `false` (mismatch) both take the invalid-credentials path; the nil path burns a dummy bcrypt comparison so an unknown account and a wrong password cost the same time
5. Role resolution: explicit → `default_role` → first assigned. Roles are referenced by their qualified id (`iam.Roles.{name}`) and resolved strictly by `projections.id` — no bare-name fallback. A role string that does not match an `iam.Roles` projection id fails with `403 "Role not found or disabled"`. A roleless account with no explicit election runs under the seeded `iam.Roles.anonymous` role (B-120) — it can authenticate, so it must be able to connect; the frontend renders the no-role screen from the emitted `available_roles` (empty) / `active_role` (anonymous) pair. An explicit election the account does not hold still fails with `403`.
6. MFA gate — if the account document's `mfa_enabled` field is true and TOTP enabled in config, create Redis challenge
7. Token emission — create session, build permission manifest, emit via `TokenEmitter`

**Failed attempts and the audit log.** A wrong password increments the attempt counters (`LoginThrottle`) and returns `401` with `remaining_attempts` in the error `meta` — the same signal the MFA challenge answers carry. Only the lockout writes an `iam.LoginEvent` row: per-attempt rows are too many, so the design keeps them out of the event log. Every failed attempt goes to the backend log instead (`facet.iam.login`, `warn` level: account id, client IP, remaining attempts). An organization that needs per-attempt auditing reads the backend log.

If `must_change_pw` is true on the account document, the pipeline short-circuits between steps 4 and 5 with `PasswordChangeRequired`. The accompanying `change_token` is a one-shot Redis credential (TTL `iam.change_password_expiration`, default 24h) consumed by `POST /Api/iam/change-password`. **The route always requires `old_password` alongside `change_token` (and `new_password`)** — the old password is verified against the stored hash on both authorization paths (bootstrap token and authenticated session) so the failure surface stays identical. Per-IP attempt counters are incremented only when `ip` is non-nil.

**`pending` is password-login-only.** `pre_auth_checks` accepts `pending` alongside `active` — an invited account completes its bootstrap through the login pipeline. The acceptance lives here exclusively: `ApiKey.verify` and every app-token liveness check require `status == "active"`.

**Enroll-at-login.** Under `iam.mfa.enforcement: always`, an account without a TOTP seed cannot pass the MFA gate. The branch runs after the password-change gate and before the challenge gate: it calls `MFA.setup` (storing the provisional secret on the `mfa` slot), creates a one-shot enroll token, and returns `EnrollmentRequired` instead of tokens. The gate is one shared predicate (`IAM::Policy.enroll_hold?`) — the invite-link first-credential confirm holds an un-enrolled account the same way (see `PasswordReset` below).

The hold is by design and has no exit: the enrollment flow offers no back or cancel, and the account stays at the enrollment step until it verifies a code. No full session exists during the hold — the enroll token authorizes only the enroll-verify route, and token refresh needs a session. An organization that wants an exit uses the `preferred` enforcement level.

**Bootstrap flip.** Every full login that issues tokens to a still-`pending` account flips it to `active` through `AccountPatch` before emission. The flip is idempotent — a no-op patch is a success.

**Delivery mode is remembered (B-278).** Login stores the token-delivery mode on the session: `cookie: false` starts a body-mode session; the absent flag or `cookie: true` starts a cookie-mode session. The MFA-challenge, enroll-at-login, and password-reset paths carry the login request's flag, so they store the same mode. Refresh enforces the stored mode — see `Facet::IAM::Refresh` below.

### `Facet::IAM::Challenge`

Verifies an MFA challenge. Called by the frontend after receiving `MFARequired` from login.

```crystal
result = Challenge.call(db, challenge_id, "123456")                  # TOTP (default)
result = Challenge.call(db, challenge_id, "8a1f-2034", "backup_code") # single-use backup code
case result
in Challenge::TokensEmitted   # MFA passed, tokens ready
in Facet::ServiceError        # invalid code, expired, locked out
end
```

The `method` parameter selects the factor: `"totp"` (default) validates against the sealed `mfa` slot; `"backup_code"` consumes one of the account's single-use backup codes (`IAM::BackupCodes`) — the self-recovery path when the authenticator is lost. Both methods share the same challenge record, expiry, and attempt limiter: a wrong answer (including a replayed or already-used code) burns one attempt, and at zero the challenge dies, the account locks out, and the event is `lockout`.

**Security features:**
- Replay protection (TOTP) — `AuthState.try_advance_totp_step`: an atomic conditional upsert on `auth_state.last_totp_step` (`… WHERE last_totp_step IS NULL OR last_totp_step < $step`); 0 rows affected = replay. This closes the TOCTOU race where two concurrent requests with the same TOTP code both passed the read-side check.
- Replay protection (backup code) — the consume is its own guard: one atomic `UPDATE … WHERE used_at IS NULL`, so a code works exactly once no matter how many concurrent requests race with it.
- Challenge expiry — Redis TTL (5 minutes)
- Attempt counting — challenge deleted after 5 failures, account lockout set
- Reuse prevention — challenge deleted on success so the same `challenge_id` cannot be replayed

### `Facet::IAM::Refresh`

Rotates tokens. Supports optional role change during refresh.

```crystal
result = Refresh.call(db, refresh_token, role: "editor", cookie: false)
case result
in Refresh::TokensEmitted
in Facet::ServiceError
end
```

**Reuse detection:**
The refresh token is an opaque `session_id.refresh_id` pair. On rotation:
- The current `refresh_id` moves to `prev_refresh_id`
- A new `refresh_id` is generated
- During the grace window (`refresh_grace_window`), both `refresh_id` and `prev_refresh_id` are accepted (`:valid` and `:grace`)
- A token that matches neither deletes the session and writes a `refresh_reuse` audit event

The reuse kill revokes the session immediately; the access token already issued against it stays valid to its TTL (the same rule as explicit revocation — see the `DELETE /Api/iam/sessions/:session_id` route below).

**Delivery-mode gate (B-278):**
The session stores how login delivered its tokens (`cookie` vs `body`). Refresh rejects a mismatch with `422` before any state changes: the refresh id does not rotate, the session stays, and the grace-window state is untouched. A body-mode session (login with `cookie: false`) refreshes only with `cookie: false` — the absent flag and `cookie: true` both answer `422`. A cookie-mode session answers `422` to `cookie: false`; the absent flag or `cookie: true` behave as before (cookies set, manifest body without tokens). The gate runs before reuse detection, so a mismatched request can never delete a session.

**Role switch:**
`POST /Api/iam/refresh` accepts an optional `role` in the body. When present, the session's `active_role` rotates to that role and the returned manifest is derived from it. The switch is rejected with `403 "Role not assigned"` when the role is not in the account's `roles` array, or `403 "Role not found or disabled"` when the role document does not exist. The frontend uses this to power the sidebar's **Switch Role** submenu (`auth.svelte.ts` → `switchActiveRole`). A roleless account's session (active role `iam.Roles.anonymous`, no explicit `role`) refreshes under the anonymous role (B-120).

### `Facet::IAM::Logout`

```crystal
Logout.call(db, session_id)  # deletes session + writes logout event
```

### `Facet::IAM::PasswordReset`

Handles forgot-password / password reset. Two-phase flow:

```crystal
# Request — always returns Requested (no enumeration)
result = PasswordReset.request(db, email: "user@example.com", reset_link_base: "https://app/ResetPassword")
case result
in PasswordReset::Requested   # 200 OK — email sent when the account can confirm
in Facet::ServiceError        # never returned by request
end

# Confirm — consumes the token, sets the password
result = PasswordReset.confirm(db, token: "...", new_password: "new-password-1", cookie: true)
case result
in PasswordReset::Confirmed       # existing credential — the account logs in with the new password
in PasswordReset::SessionStarted  # first credential — bootstrap session emitted
in Facet::ServiceError            # 422 (short password) / 401 (bad token)
end
```

**Security properties:**
- **Anti-enumeration**: `request` always returns `Requested` (HTTP 200). When the email matches no account, the call is a silent no-op — no email is sent, no token is created, but the response is identical to a successful request. The HTTP body is `{ok: true, link_ttl_seconds}` — the TTL is config-derived (`iam.change_password_expiration`), never account-derived, so the field carries no enumeration signal. Clients state the effective link validity in their copy from it.
- **Password-slot guard**: a link is minted and sent only when the account exists and holds a `password` slot. A credential-less account (first-invite pending, or a service account) would receive a link whose confirm can never succeed — so the request is a silent no-op for it.
- **Token storage**: the `reset` slot of the `secrets` store, `mode: token` with a TTL of `iam.change_password_expiration` (default 24h). `Secrets.set` digests the raw token (SHA-256); only the email ever sees the raw value. The same slot serves the invite link (see `Invite.send_invite`), so a second link replaces the first.
- **Single-use consume**: `confirm` runs `Secrets.consume(db, "reset", token, domain: "iam")` — one atomic `DELETE … RETURNING` with the TTL check in the same statement. Zero rows means missing, expired, or already used — the caller fails closed. A short-password rejection does NOT consume the token (it is a client error checked before token consumption).
- **First-credential bootstrap**: when the account held no `password` slot (an operator invite accepted), the confirm writes the `password` slot, flips `pending → active`, emits a session alongside the token response (cookie mode follows the `cookie` parameter), and writes `invite_accepted`. Under MFA enforcement `always` with an un-enrolled account the session is withheld: the confirm returns `EnrollmentHeld`, the route answers `{ok: true}`, the `invite_accepted` event still lands (its details mark the hold), and the sign-in that follows holds at the enrollment step (B-141). When a credential already existed, no session is issued — the account logs in with the new password — and the event is `password_reset_used`. The confirm also clears `must_change_pw`; on the invite path that clear is by design — the invitee sets their own password, so the forced-change gate has nothing left to force.
- **Convergence**: the pending link is already gone when the password write happens — the consume above deleted the row.
- **Audit**: `request` writes `password_reset_requested`, `confirm` writes `invite_accepted` (first credential) or `password_reset_used`.

### `Facet::IAM::Invite`

Credential bootstrap for invited accounts — the services behind the operator routes `POST /Api/iam/accounts/:id/temporary-password` and `POST /Api/iam/accounts/:id/invite`, plus the read behind `GET /Api/iam/accounts/credential-states`.

```crystal
# Temporary password — plaintext returned exactly once
result = Invite.generate_temporary_password(db, account_id, set_by: operator_id)
case result
in Invite::Generated          # => result.password (reveal once, never stored or emailed)
in Facet::ServiceError        # 422: missing account, service account, suspended/disabled
end

# Invite link — single-use token + email
result = Invite.send_invite(db, account_id, set_by: operator_id)
case result
in Invite::InviteSent         # => result.first_invite (true when no password slot existed)
in Facet::ServiceError        # 422: missing account, service account
end

# Credential states — one entry per requested id
states = Invite.credential_states(db, account_ids)  # => Array(Invite::CredentialState)
```

**Temporary password.** 16 characters over a 30-symbol alphabet (Crockford Base32 minus `0` and `1`), joined as 4 groups of 4 with dashes — matching `^[2-9A-HJKMNP-TV-Z]{4}(-[2-9A-HJKMNP-TV-Z]{4}){3}$`, safe to read aloud or type. `Random::Secure.rand(30)` draws each character uniformly. In one transaction the service stores the bcrypt hash on the `password` slot, sets `must_change_pw: true`, and clears the `reset` slot (the convergence rule — a password write kills any pending invite link). The event is `temp_password_generated`; the `details` field never carries the plaintext. The plaintext is shown exactly once by the route — never stored, emailed, or logged.

**Invite link.** Mints a single-use token, stores it on the `reset` slot (`mode: token`, TTL `iam.change_password_expiration`), and emails `{scheme_base_url}/ResetPassword?token=…` through `InviteEmail`. A second invite overwrites the slot, so the previous email's link dies immediately. `suspended` and `disabled` are allowed — the operator may bring the account back through the invite; the invitee can accept the link and set a password, but the sign-in itself still needs `active` (`pre_auth_checks`). This is the deliberate asymmetry with the temporary password, which is refused for those statuses because the recipient could not use it. The event is `invite_sent`; no token material lands in `details`.

**Credential states.** One SQL query LEFT JOINs `secrets` twice (once per slot) and returns one entry per requested id:

| Field | Meaning |
|---|---|
| `id` | Account id |
| `has_password` | A `password` slot row exists |
| `must_change_pw` | The account document field |
| `mfa_enabled` | The account document field |
| `invite_pending` | A live `reset` slot exists (`mode: token`, not expired) |
| `federated` | The account's `federated_identities` array is non-empty (see [`oidc.md`](oidc.md)) |

Ids with no live account row are skipped; an empty id list returns an empty array.

### `Facet::IAM::MFA`

```crystal
# Setup — generates provisional secret, returns otpauth:// URI
MFA.setup(db, account_id, account_name)    # => SetupResult | Facet::ServiceError

# Verify — confirms TOTP code round-trips, enables MFA, mints backup codes
# Rate-limited: 5 invalid attempts per 5-minute window (429 after).
MFA.verify(db, account_id, code)            # => VerifyResult | Facet::ServiceError

# Disable — admin recovery path
MFA.disable(db, account_id)                 # => Nil | Facet::ServiceError (nil on success)
```

`VerifyResult#backup_codes` carries the account's fresh single-use backup codes (see `Facet::IAM::BackupCodes` below) — the HTTP route returns them in the same response, and they are shown exactly once.

**Brute-force protection:** `POST /Api/iam/mfa/totp/verify` is guarded by a Redis counter (`mfa_verify_attempts:{account_id}`, 5 attempts, 5-minute TTL) matching the login-challenge limiter. On success the counter is reset. Replay protection uses the atomic `AuthState.try_advance_totp_step` guard (same mechanism as `Challenge`). The enroll-at-login flow has its own attempt counter, stored on the enroll token itself — see `Facet::IAM::Enroll` below.

**Storage contract:**
- `setup` writes the TOTP seed into the account's `mfa` slot (`mode: sealed`, `meta.mfa_type = "totp"`) — a slot write only; no document mutation, so `mfa_enabled` stays untouched until verify.
- `verify` reveals the seed (`Secrets.reveal`), TOTP-validates, advances the replay guard, then flips the account document's `mfa_enabled` field via `AccountPatch` and mints a fresh backup-code set (replacing any previous one).
- `disable` clears the `mfa` slot, resets the `auth_state` step counter, deletes the backup codes, and flips the field to false — all writes in one transaction.

### `Facet::IAM::Enroll`

Completes the enroll-at-login flow (MFA enforcement `always`). The login branch withheld the session and returned a one-shot enroll token plus the provisional TOTP secret; this service validates the first code, flips `mfa_enabled`, and emits the session the login withheld. The enroll token is the only authorization — no session exists yet.

```crystal
result = Enroll.verify(db, enroll_token, "123456")
case result
in Enroll::TokensEmitted      # enrollment complete, tokens ready
in Facet::ServiceError        # 401 / 429 — see below
end
```

Pipeline: load the enroll token (missing or expired → the account must re-login) → reveal the provisional `mfa` slot → `TOTP.validate` → advance the replay guard (`AuthState.try_advance_totp_step`, same semantics as the challenge flow) → flip `mfa_enabled` via `AccountPatch` → delete the enroll token (the token is single-use) → write `mfa_enrolled` → flip a still-`pending` account to `active` → emit the session via `SessionEmit` → mint the backup-code set. `Enroll::TokensEmitted` carries `result` (the token emission) plus `backup_codes` — the raw codes ride on the HTTP response and are shown exactly once.

An invalid code decrements the token's `attempts_remaining`. At zero the token dies, the account locks out, and the event is `lockout` — mirroring `Challenge.handle_invalid_code`.

### `Facet::IAM::BackupCodes`

Single-use MFA backup codes — the self-recovery path for a lost authenticator. A fresh set is minted every time a TOTP enrollment completes (`MFA.verify` and `Enroll.verify`); the raw codes are returned once and shown to the account, and only SHA-256 digests are stored, in the dedicated `mfa_backup_codes` table (migration `0011_secrets.sql`) — the same secret-storage precedent as `api_keys`, never in the event log.

```crystal
generated = BackupCodes.generate(db, account_id)  # => Generated (codes shown once, replaces the old set)
BackupCodes.consume(db, account_id, "8a1f-2034")  # => Bool — atomic single use
BackupCodes.remaining(db, account_id)             # => Int64 — unconsumed codes
BackupCodes.clear(db, account_id)                 # => Nil — MFA disable hygiene
```

- **Format** — 10 codes per set; each is 8 random hex characters (`Random::Secure`, 32 bits) displayed as `xxxx-xxxx`. Combined with the challenge limiter (5 bad answers delete the challenge and lock the account) online guessing is impractical while the codes stay typable from paper.
- **Normalization** — the digest is of the normalized form (lowercased, all non-alphanumerics stripped), so the display form, the bare `xxxxxxxx`, and any uppercased typing all verify.
- **Single use** — `consume` is one atomic UPDATE that only matches rows still unused (`used_at IS NULL` in the same statement); a replayed code fails and burns a challenge attempt like any wrong guess.
- **Regeneration** — `generate` deletes the account's existing rows before inserting the new set, so re-enrollment rotates the codes; `MFA.disable` clears them with the rest of the MFA state.

### `Facet::IAM::SessionEmit`

The shared token-emission step for every path that authenticates an account without a session: password login, MFA challenge, enroll-at-login, and OIDC login. It loads the account, verifies the active role is still assigned (the anonymous fallback excepted), creates the Redis session, builds the permission manifest, and emits the token pair. The emitted shape is identical across callers. A roleless account runs under the seeded `iam.Roles.anonymous` role (B-120): the emitted `available_roles` stays the account's assigned roles (empty) and `active_role` is the anonymous role id — the frontend detects the state from that pair.

```crystal
result = SessionEmit.call(db, account_id, active_role, cookie_requested,
  user_agent: nil, ip: nil)  # => TokenEmitter::Result | ServiceError
```

`user_agent` and `ip` are available only on the password-login path, which sees the request.

### `Facet::IAM::AuthState`

Volatile operational state for accounts, keyed by document — same storage family as `account_settings`: not a secret, not document data. Lives outside the doctype system because it must never enter the event log and carries no audit value. The `auth_state` table currently holds one column, `last_totp_step`, the TOTP replay guard.

```crystal
AuthState.try_advance_totp_step(db, doc_ref, step) # => Bool (atomic; false = replay)
AuthState.reset_totp_step(db, doc_ref)             # => Nil (MFA disable / recovery)
```

### `Facet::IAM::AccountPatch`

Flips account document fields with the system principal — the same pattern the invite flow uses for status flips. `Document::Update` treats a no-op patch as success, so repeated flips are safe. The human-facing audit trail lives in `iam.LoginEvent` rows.

```crystal
AccountPatch.call(db, account_id, {"mfa_enabled" => JSON::Any.new(true)}) # => Update::Result | ServiceError
```

Used by `MFA.verify` / `MFA.disable` (the `mfa_enabled` flag) and by the password flows (`must_change_pw`). The patch only carries document fields — secret material goes through the `Secrets` store, never through here.

### `Facet::IAM::RedisSession`

Manages browser and app sessions in Redis. The lockout flag and the
attempt counters live in `LoginThrottle`; the one-shot bootstrap and
enroll tokens live in `PwdChangeToken` and `EnrollToken`.

| Method | Returns | Description |
|---|---|---|
| `.create(account_id, active_role, ...)` | `{session_id, refresh_id}` | Creates a session hash + account session set entry |
| `.create_app_session(account_id, active_role, app, client_id, ...)` | `{session_id, refresh_id}` | Creates an app session bound to the OAuth `client_id`; registers it in `app_sessions:{app_id}` |
| `.load(session_id)` | `Session?` | Loads session by ID |
| `.rotate(session_id, ...)` | `String?` | Rotates refresh_id, returns new refresh_id |
| `.validate_refresh_id(session, presented)` | `:valid \| :grace \| :stale` | Reuse detection |
| `.delete(session_id)` | `Nil` | Deletes session + removes it from the account and app sets |
| `.delete_app_sessions(app)` | `Int32` | Deletes every session of one app (per-app revocation) |
| `.list_account_sessions(account_id)` | `Array(String)` | Device enumeration |
| `.list_account_app_sessions(account_id, app)` | `Array(String)` | Session ids the account holds for one app |

The Redis connection is shared: `RedisSession.redis` is the connection
point for `LoginThrottle`, `PwdChangeToken`, `EnrollToken`, the MFA
challenge store, and the OIDC state store.

**Redis key structure:**
- `session:{session_id}` — hash: `refresh_id`, `prev_refresh_id`, `account_id`, `active_role`, `created_at`, `last_used_at`, `refresh_issued_at`, `user_agent`, `ip`, `app`, `client_id?`, `dpop_jkt?`, `token_delivery?` (written only for body mode — see `Refresh`)
- `account_sessions:{account_id}` — set of session_id strings
- `app_sessions:{app_id}` — set of session_id strings (app sessions only)
- `challenge:{challenge_id}` — hash: `account_id`, `active_role`, `type`, `cookie_requested`, `attempts_remaining`
- `oidc:state:{state}` — one-shot JSON string consumed with `GETDEL` (OIDC flow state — see [`oidc.md`](oidc.md))

Reset and invite link tokens are not in Redis — they are `reset`-slot rows in the `secrets` store (see the Storage Split and [`secrets.md`](secrets.md)).

### `Facet::IAM::LoginThrottle`

Login throttle state in Redis (`src/iam/login_throttle.cr`): the
lockout flag and the brute-force attempt counters. Spec:
`spec/iam/login_throttle_spec.cr`.

| Method | Returns | Description |
|---|---|---|
| `.locked_out?(account_id)` | `Bool` | Checks the `login_lockout:{account_id}` key |
| `.set_lockout(account_id, ttl = 300)` | `Nil` | Sets the lockout key with a TTL (default 5 minutes) |
| `.increment_pwd_attempts(account_id)` | `Int32` | Increments and returns the password attempt count |
| `.get_pwd_attempts(account_id)` | `Int32` | Reads the count without incrementing |
| `.increment_ip_attempts(ip)` | `Int32` | Per-IP attempt counter |
| `.get_ip_attempts(ip)` | `Int32` | Reads the IP attempt count |
| `.reset_pwd_attempts(account_id, ip = nil)` | `Nil` | Deletes the account and IP password counters (after a successful login) |
| `.increment_mfa_verify_attempts(account_id)` | `Int32` | Increments the MFA verify attempt count |
| `.get_mfa_verify_attempts(account_id)` | `Int32` | Reads the MFA verify attempt count |
| `.reset_mfa_verify_attempts(account_id)` | `Nil` | Resets the MFA verify counter (on success) |

Each counter sets its TTL on the first increment and expires after the
window (default 300 s); a later increment does not extend it. The counters and
the `login_lockout` flag are distinct keys with independent TTLs — the flag's
300 s start when it is set, not when the counter that triggered it started.

**Redis key families:**

| Key | Purpose |
|---|---|
| `login_lockout:{account}` | Present while the account is locked out. Login refuses with `429` while it exists |
| `pwd_attempts:{account}` | Failed password attempts for the account — the counter that feeds the lockout (at `MAX_PWD_ATTEMPTS` = 10, the next pre-auth check sets the lockout flag and answers `429`) |
| `pwd_attempts:ip:{ip}` | Failed password attempts from one client IP address — `{ip}` is the resolved client IP (`Util::ClientIp`, see [`util-client-ip.md`](util-client-ip.md); a bare host, never the socket port). At `MAX_IP_ATTEMPTS` = 20, login refuses with `429`; it does not set the lockout flag |
| `mfa_verify_attempts:{account}` | Failed MFA verify attempts at the enroll-verify endpoint (at 5, that endpoint answers `429`; it does not set the lockout flag). Also used after sign-in by the standalone TOTP verify endpoint (`IAM::MFA.verify`) |

The login-challenge MFA lockout (too many invalid TOTP codes) sets the same
`login_lockout` flag directly; its attempt counter lives in the challenge
hash, not in these keys. The enroll-at-login lockout works the same way: its
attempt counter lives on the one-shot `enroll:{token}` hash.

**Operator runbook — clearing a lockout.** To clear a full lockout, delete
all four families — the lockout flag plus every counter the gates read. For
a password-only clear, delete the three password families
(`login_lockout:{account}`, `pwd_attempts:{account}`, `pwd_attempts:ip:{ip}`)
and keep `mfa_verify_attempts:{account}` so the MFA limiter stays intact.
Keys expire on their own after the window (300 s) when you leave them alone.

### `Facet::IAM::PwdChangeToken`

One-shot password-change bootstrap tokens in Redis
(`src/iam/pwd_change_token.cr`). Login creates a token when
`must_change_pw` is set; the change-password route consumes it. Key:
`pwd_change:{token}` — hash `{account_id, attempts_remaining}` (5
attempts, TTL `iam.change_password_expiration`).

```crystal
PwdChangeToken.create_pwd_change_token(account_id, ttl)  # => String
PwdChangeToken.consume_pwd_change_token(token)           # => String? (account id while valid)
PwdChangeToken.delete_pwd_change_token(token)            # => Nil
PwdChangeToken.mark_pwd_change_token_used(token)         # => Nil
PwdChangeToken.used_pwd_change_token?(token)             # => Bool
```

Each consume decrements `attempts_remaining`. The store deletes the
token when no attempts remain.

A successful password change marks the token used, then deletes it (a
crash between the two steps still leaves the marker). The marker key
`pwd_change:used:{token}` carries a 300 s TTL and stays under the
`pwd_change:` prefix, so the Redis cleanup sweeps it. When a retry
finds no token but the marker exists, the route answers `401` with a
distinct message: the change succeeded; sign in with the new password.
After the marker expires, a retry gets the generic `invalid or
expired` answer. The change stays in force in both cases.

### `Facet::IAM::EnrollToken`

One-shot enroll-at-login tokens in Redis (`src/iam/enroll_token.cr`).
The login branch creates a token when the MFA policy enforces
enrollment; the enroll-verify route consumes it. Key: `enroll:{token}`
— hash `{account_id, active_role, cookie_requested,
attempts_remaining}` (5 attempts, TTL 300 s — matches the challenge
window). The token is always single-use: the store deletes it on
success, on a replayed code, and on exhausted attempts.

```crystal
EnrollToken.create_enroll_token(account_id, active_role, cookie_requested)  # => String
EnrollToken.load_enroll_token(token)              # => EnrollToken?
EnrollToken.decrement_enroll_attempts(token)      # => Int32 (0 or less = delete)
EnrollToken.delete_enroll_token(token)            # => Nil
```

### `Facet::IAM::JWT`

ES256 JWT sign/verify with mandatory algorithm pinning.

```crystal
JWT.sign(payload, pem_key, kid: "facet-1")          # => String (signed JWT)
JWT.decode(token, pem_key)                            # => Decoded | raises Error
JWT.build_access_payload(account_id, session_id, role)  # => {Hash, Int64} (payload + exp timestamp)
JWT.build_app_payload(account_id, sid, role, app_id)    # => {Hash, Int64} (typ: "app" payload + exp timestamp)
JWT.generate_key_pem                                 # => String (P-256 PEM)
```

**Security properties:**
- Algorithm always pinned to ES256 — the JWT header `alg` is never trusted
- `kid` identifies the signing key (for rotation)
- Standard claims on every token: `sub` (account_id), `sid` (session id), `role`, `jti`, `typ`, `iat`, `exp`
- `typ` distinguishes token kinds: `ACCESS_TOKEN_TYP = "access"` (browser-session tokens issued by login/refresh) and `APP_TOKEN_TYP = "app"` (OAuth app tokens issued at `POST /OAuth/token`)
- Access token TTL is configurable (default 900s / 15 min)

**Signing key.** The `JWT_SIGNING_KEY` environment variable holds the ES256 signing PEM — a P-256 private key in PEM form. `TokenEmitter.signing_key` reads the variable at first use and memoizes the key for the process lifetime. When the variable is unset, each process generates its own key at first use and logs a one-time warning; this is a dev/test convenience. Production and multi-instance deployments must set `JWT_SIGNING_KEY`: a restart with a generated key invalidates all outstanding access tokens (clients get `401` until re-login), and instances cannot verify each other's tokens. Generate a key with `openssl ecparam -name prime256v1 -genkey -noout`.

**App tokens (`typ: "app"`).** The app-token payload carries an additional `app` claim (the `app.App` projection id) and a fresh opaque `sid` that is **not** a `RedisSession` session id — app sessions are independent from the browser session that authorized them. `AuthHandler` branches on `typ: "app"`: it reads `app`, reloads the `app.App` projection (gates on `status == "active"`), re-resolves the grant through `GrantResolver.role_usable?` + `resolve`, and constructs `RBAC::AuthContext.app_scoped`. The grant is never cached on the token — it is re-resolved on every request so a grant change applies without re-issuing the token. See [`doc/backend/oauth.md`](oauth.md) for the full flow.

### `Facet::IAM::TOTP`

RFC 6238 TOTP implementation using HMAC-SHA1, 6 digits, 30-second period, vendored (~90 lines).

```crystal
TOTP.generate_secret              # => "JBSWY3DPEHPK3PXP" (base32, 160-bit)
TOTP.generate(secret)             # => "123456"
TOTP.validate(secret, code)       # => Int64? (time step or nil)
TOTP.otpauth_uri(secret, account) # => "otpauth://totp/..."
```

### `Facet::IAM::TokenEmitter`

Shared output path for login, challenge, and refresh. Builds the `Result` record and serializes it as JSON body or HttpOnly cookies.

```crystal
TokenEmitter.emit(cookie: false, account_id: "...", ...)  # => Result
TokenEmitter.response_body(result)   # => JSON string (cookie mode — no tokens in body)
TokenEmitter.full_body(result)       # => JSON string (no-cookie mode — includes tokens)
TokenEmitter.set_cookies(env, result) # sets auth_token + refresh_token cookies
```

The `Result` record carries: `account_id`, `email`, `display_name`, `mfa_enabled`, `active_role`, `available_roles`, `session_id`, `refresh_id`, `access_token`, `refresh_token`, `permissions`, `scopes`, `cookie`.

### `Facet::IAM::Seed`

Bootstraps admin accounts:

```crystal
Seed.seed_admin(db, email)  # => Admin? (id, email, password) — nil when the email is taken
Seed.seed_dev_admin(db)     # => Bool (true created, false reset) — dev only
Seed.dev_seed_refusal       # => String? — the seed:dev refusal message in production
```

`seed_admin` (wired to `facet seed:admin` — see [`cli.md`](cli.md) and [`doc/ops/first-deployment.md`](../ops/first-deployment.md)) creates the first admin Account with a generated one-time password (`Invite.generate_password` — 16 characters over the 30-symbol alphabet), `must_change_pw: true` as a document field, and the admin's bcrypt hash in the `password` slot of the secret store. The plaintext returns once — the CLI prints it; nothing stores it in plaintext and nothing logs it. The bootstrap never resets an existing credential; a taken email returns `nil`.

`seed_dev_admin` (dev mode only) creates or resets the dev admin with `must_change_pw: false`. The CLI refuses the command when `APP_ENV=production` (`dev_seed_refusal` — the same fail-closed pattern as the mail adapter gate). On the reset path it first deletes every side-table row keyed by the account id — `secrets` slots, `auth_state`, `account_settings`, `notifications` — since no FK cascade points at the account id anymore.

### `Facet::IAM::ApiKey`

Static bearer keys for machine-to-machine access. A key pins one `{account, role}` pair; the pair is fixed at creation. Requests authenticate with `Authorization: Bearer fct_…` — `AuthHandler` branches on the `fct_` prefix before JWT decoding. A plain self-service key builds the same `AuthContext.authenticated` a browser session gets, plus an `api_key_id` provenance tag. A row with `app_id` set is an **app-owned key** (backend apps): verification additionally gates the app's liveness, and the request builds an `AuthContext.app_scoped` (grant ∩ pinned role) — see [`app-system.md`](app-system.md#backend-apps-—-service-account-+-api-key).

```crystal
# Token format: `fct_` + 26 Crockford Base32 chars (130 bits, no timestamp).
token = ApiKey.generate_token

# One-time creation — storage keeps only a SHA-256 hash and a display prefix.
# `app_id` tags an app-owned key (backend apps); nil is a self-service key.
created = ApiKey.generate(db, account_id, "iam.Roles.admin", "ci-pipeline",
  expires_at: "2026-12-31T23:59:59Z"?, app_id: nil?)  # => ApiKey::Created(id, key, display_prefix, expires_at)

# Per-request verification — all checks run every request, so a key dies
# immediately with revocation, expiry, role unassignment, account deletion,
# or account disablement/suspension. Role deletion is observed through the
# role content cache (see `IAM::RoleStore` below): bounded by the fanout
# round trip, or by `cache.staleness_ttl_s` when a fanout is lost.
verified = ApiKey.verify(db, token)  # => ApiKey::Verified? (nil on any failure)

ApiKey.list(db, account_id)           # => Array(ApiKey::Row) — never the secret
ApiKey.revoke(db, account_id, key_id) # soft revoke, idempotent
```

Verification pipeline: SHA-256 lookup by unique index → not revoked, not expired → account projection live and `status == "active"` → `role_id ∈ account.roles` → role projection present (read through `IAM::RoleStore`) → the pinned role's `connectivity` list carries the `api` channel (a role edited down to browser-only kills every key pinned to it on their next use; a missing or malformed list reads as empty and fails closed). Every failure is a bare 401 (anti-enumeration). `last_used_at` is touched at most once per minute per key.

Every mutation written through a key carries the `api_keys.id` row ULID in the `mutations.api_key` column (see [`mutation.md`](mutation.md)), so an audit view can answer "which key wrote this mutation" and join it to `api_keys.display_prefix` + `name` for a human label.

Service accounts (`service_account: true` on `iam.Account`) are the intended key holders for machine flows: they cannot log in with email + password (403 from `Login`) and password-reset requests for them are silent no-ops.

Diagnosing an opaque 401 on an app-owned key or an app token: a credential that verifies but still answers a bare 401 usually points at an empty grant ∩ role — a role edited after issuance, or a key issued before the empty-intersection gate existed. The 401 body names nothing (anti-enumeration). Read the server log instead: `AuthHandler` writes one WARN on `facet.http.auth` that names the app, the role, and (for a key) the key id — `app-owned API key refused…` / `app token refused…`. The request span carries `auth.refused = "empty_scope"`. For an app-owned key whose role lost a required grant action, the span carries `auth.refused = "role_unusable"` and `auth.missing_actions`.

### `Facet::IAM::RoleStore`

Process-local cache for `iam.Roles` projection content (`src/iam/role_store.cr`). Every role read — the `AuthHandler` builders (authenticated, anonymous, app token), `ApiKey.verify`, login, refresh, MCP dispatch, OAuth consent, assistant gate — goes through `IAM::Helpers.find_role_content`, which delegates here, so the cache covers authenticated and unauthenticated callers alike.

| Method | Returns | Description |
|---|---|---|
| `RoleStore.fetch(db, qualified_id)` | `JSON::Any?` | Role content by qualified id (`iam.Roles.admin`), through the configured cache; `nil` when absent or deleted |
| `RoleStore.invalidate(qualified_id)` | `Nil` | Evicts one role's entry (hit or keyed miss) — the fanout path |
| `RoleStore.cache` / `cache=` | `Cache` | The active implementation; `main.cr` installs `ProcessCache` for the server command, the default is `PassThrough` (CLI, specs) |

Invalidation follows the shared invalidate-only contract: `Event::Subscriber::RoleCache` evicts on every `fanout:iam.Roles:*` message, and entries reload past `cache.staleness_ttl_s` (`Util::CacheFreshness`) when a fanout is lost — `0` disables the bound. A mutation's visibility to concurrent readers is bounded by the Pub/Sub round trip. Cached content is shared read-only across fibers.

## HTTP Routes

All routes are under `/Api/iam`. State-changing requests require the `X-Requested-With` header (CSRF defense for cookie auth); a request without it is rejected with `403 {"error": "CSRF: Missing X-Requested-With header"}`. Requests authenticated solely by an API key (`Authorization: Bearer fct_…`, no session cookie) skip the check — a browser never attaches an Authorization header to cross-site requests, so there is no ambient credential to abuse.

| Method | Path | Handler | Description |
|---|---|---|---|
| `POST` | `/Api/iam/login` | `Login.call` | Authenticate with email + password |
| `POST` | `/Api/iam/challenge` | `Challenge.call` | Complete MFA challenge (TOTP code or single-use backup code) |
| `POST` | `/Api/iam/mfa/enroll/verify` | `Enroll.verify` | Complete enroll-at-login (public — the one-shot enroll token is the authorization) |
| `POST` | `/Api/iam/refresh` | `Refresh.call` | Rotate tokens |
| `POST` | `/Api/iam/logout` | `Logout.call` | Destroy session + clear cookies |
| `GET` | `/Api/iam/me` | (route inline) | Current account profile, token expiration, and nav data |
| `GET` | `/Api/iam/apps` | `AppLauncher.launcher_apps` | Launcher apps for the active role (active, not marked `no_launcher`), each flagged `usable` (grant-satisfiable) |
| `POST` | `/Api/iam/change-password` | (route inline) | Change password (bootstrap via `change_token` or authenticated session) |
| `POST` | `/Api/iam/password-reset/request` | `PasswordReset.request` | Anti-enumeration reset-link request |
| `POST` | `/Api/iam/password-reset/confirm` | `PasswordReset.confirm` | Validate reset token + set new password (first credential auto-logs in; no session under `always` enforcement — the sign-in holds at enrollment) |
| `POST` | `/Api/iam/accounts/:id/temporary-password` | `Invite.generate_temporary_password` | Operator action — temporary password, plaintext returned once (RBAC: `provision_credentials`) |
| `POST` | `/Api/iam/accounts/:id/invite` | `Invite.send_invite` | Operator action — email a single-use invite link (RBAC: `provision_credentials`) |
| `GET` | `/Api/iam/accounts/credential-states` | `Invite.credential_states` | Operator read — one state per `?id=` query parameter (repeatable; a value may also carry a comma-joined list, per the query list grammar); the batch read behind the account admin tables (RBAC: `provision_credentials`) |
| `POST` | `/Api/iam/mfa/totp/setup` | `MFA.setup` | Generate provisional TOTP secret |
| `POST` | `/Api/iam/mfa/totp/verify` | `MFA.verify` | Confirm TOTP + enable MFA; response carries the one-time backup codes |
| `POST` | `/Api/iam/mfa/disable` | `MFA.disable` | Admin recovery — disable MFA (RBAC-gated: requires `mfa_disable`) |
| `POST` | `/Api/iam/keys` | `ApiKey.generate` | Create an API key for the caller — `role` must be a fully-qualified `iam.Roles.{name}` reference assigned to the caller, the role must exist, and its `connectivity` must carry the `api` channel; each failure answers `422` with its own message; raw key returned once |
| `GET` | `/Api/iam/keys` | `ApiKey.list` | List the caller's keys (never the secret) |
| `DELETE` | `/Api/iam/keys/:key_id` | `ApiKey.revoke` | Soft-revoke one of the caller's keys (idempotent; ownership-gated) |
| `GET` | `/Api/iam/sessions` | (route inline) | List the caller's own sessions (browser + app); ids + metadata, no refresh tokens |
| `DELETE` | `/Api/iam/sessions/:session_id` | (route inline) | Revoke one own session (ownership-gated; idempotent — an unknown session id answers `200 {"ok": true, "revoked": false}`, a revoked own session `200 {"ok": true, "revoked": true}`; access tokens stay valid to their TTL) |
| `DELETE` | `/Api/iam/apps/:app_id/sessions` | (route inline) | Revoke every app session of the caller for one app |
| `GET` | `/Api/iam/oidc/providers` | `OIDC::Providers.summaries` | Public — SSO button list for the login page; see [`oidc.md`](oidc.md) |

**Last-admin MFA recovery.** An admin can lose both MFA factors: the authenticator (TOTP) and the backup codes. A login then cannot complete — the login holds at the MFA gate, and the challenge accepts only a TOTP code or a backup code. Password reset does not clear MFA. `facet seed:admin` refuses an existing account. Direct database surgery is not necessary. Recover with a second admin account:

1. On the host, run `facet accounts:create <new-email> --role admin` (see [`cli.md`](cli.md)). The CLI is system-tier by design. It creates an `iam.Account` with the `admin` role and prints a one-time password exactly once.
2. Sign in as the new account. The first login forces a password change; set a new password and sign in again. Under enforcement `always`, the sign-in then holds at the enrollment step; complete the enrollment — the response carries fresh backup codes.
3. Call `POST /Api/iam/mfa/disable` with `{"account_id": "<locked account id>"}`. The route requires the `mfa_disable` permission on `iam.Account` — the seeded `admin` role holds it through its `*` on `*.*` wildcard line. `MFA.disable` clears the `mfa` slot, the TOTP step counter (replay guard), and the backup codes, and sets `mfa_enabled` to false, in one transaction. The locked account can then sign in and re-enroll.

If the locked admin still holds a live session, the admin can call the same route with that account's id. No second admin is necessary.

**Role document ids are qualified.** The id of an `iam.Roles` document is the
qualified `iam.Roles.<slug>` form (for example `iam.Roles.clerk`, not
`clerk`) on every REST route — `POST`/`GET`/`PATCH`/`DELETE` on
`/Api/iam/Roles` included. The routes pass a bare slug id through unchanged,
it matches no projection row, and the call answers `404 "Document
iam.Roles#clerk not found"`. The seeded roles carry these ids
(`iam.Roles.admin`, `iam.Roles.editor`, …). The same qualified form appears
at the login `role` election and in the `role` field of an API-key create
body (see below).

**Request/response:**

- **Login** — POST body: `{"email": "...", "password": "...", "role": "editor"?, "cookie": true?}`. `email` and `password` are required, `role` is an optional qualified role id, and `cookie` is optional — it defaults to `true`. API and script clients that want the token in the body pass `"cookie": false`; browser flows keep the default (SvelteKit SSR reads the HttpOnly cookies). Returns `TokensEmitted` (two shapes, below), `MFARequired` (`{"mfa": true, "challenge_id": "...", "type": "totp"}`), `EnrollmentRequired` (`{"mfa_enroll_required": true, "enroll_token": "...", "secret": "...", "otpauth_uri": "...", "mfa_enforcement": "always"}`), or `PasswordChangeRequired` (`{"must_change_password": true, "change_token": "..."}`). The two `TokensEmitted` shapes:
  - **Cookie mode (default)** — the tokens go into two HttpOnly cookies: `auth_token` (the access JWT) and `refresh_token` (both `path=/`, `SameSite=Lax`). The body has no `token` key: `{"account": {"id", "email", "display_name", "mfa_enabled"}, "active_role", "available_roles", "expires_at", "permissions"?, "scopes"?}`.
  - **Body mode (`"cookie": false`)** — no `Set-Cookie`. The body has the same fields plus `"token"` (the access JWT) and `"refresh_token"`. The chosen mode is stored on the session; refresh must use the same mode (see **Refresh** below).
- **Challenge** — POST body: `{"challenge_id": "...", "result": "123456", "method": "totp"?}`. `method` selects the factor: `"totp"` (default) validates a TOTP code, `"backup_code"` consumes one of the account's single-use backup codes (`IAM::BackupCodes`) — an unknown `method` answers 422. The request body has no `cookie` field — the response follows the cookie mode of the login that created the challenge (the challenge record stores it). Returns tokens on success, in the same two shapes as the login response.
- **Refresh** — POST body: `{"refresh_token": "...", "role": "editor"?, "cookie": true?}`. The refresh token also comes from the `refresh_token` cookie. `cookie` is optional and defaults to `true`; the response uses the same two shapes as the login response. The flag must match the delivery mode the session stored at login: a body-mode session refreshes only with `"cookie": false`, a cookie-mode session rejects `"cookie": false`. A mismatch answers `422 {"error": ...}` and rotates nothing (B-278).
- **Logout** — No body; session extracted from `auth_token` cookie JWT.
- **Me** — GET, no body. Returns `{"account": {"id", "email", "display_name", "mfa_enabled", "mfa_enforcement"}, "active_role", "available_roles", "expires_at", "permissions", "scopes", "assistant", "connectivity"}`. The `expires_at` field is the Unix timestamp of the access token's `exp` claim. `mfa_enabled` is the account document field; `mfa_enforcement` is the configured mode (`preferred` or `always`). The `available_roles` field is the account's assigned roles (the ids the frontend's Switch Role submenu lists). The `permissions` field is the **credential's permission manifest** (a map of `"domain.Doctype"` → actions), which the frontend uses to filter the sidebar nav model by RBAC — see **Permission manifest** below. The manifest follows the credential: a session caller (or a self-service key) reads the active role's own manifest; an app-scoped caller — an app token (`typ: "app"`) or an app-owned API key — reads the resolved grant ∩ role instead (`IAM::Helpers.build_effective_manifest` over the `AuthContext#app_grant` scope `AuthHandler` resolves per request). From the app's perspective a document its grant does not name does not exist, so the effective manifest carries only concrete keys (plus the domain-wildcard form a collapsed wildcard grant target produces), no `*.*` fallback, and no doctype outside the grant; carve-outs fold per granted action, and a fold that covers the key's own path removes the action — a carved doctype does not appear at all (see **Effective manifest** below). The `scopes` field is the per-(doctype, action) scope-alias manifest mirroring the Lua `ctx.actor.scopes` — `scopes[dt][action]` is `[]` when the permission is unrestricted (e.g. general-capable `create`) or `["mine", …]` when scoped — so the frontend can render affordances `can()` cannot express (e.g. the General/Personal toggle in the CollectionView editor). The `connectivity` field is the active role's connectivity channel list (`mcp`, `webhook`, `api`, `assistant`); a missing role reads as `[]`. The frontend hides the affordances the channels govern (Settings → API keys, the webhooks entry). The `assistant` block carries `{access, configured, token_budget, name}` — `access` is the **active role's** `connectivity ∋ 'assistant'` answer (one role per request, read off the role content the route already loads), ANDed for an app-scoped caller with the app's own `assistant_enabled` flag — the same AND `Assistant::App::Gate.allowed?` applies on the conversation create route (a missing app row fails closed) — `configured` reports whether an API key resolves installation-wide (sealed `assistant.api_key` slot, then the file's `!env?` value — `AssistantView.configured?`; `false` keeps the dock visible but the frontend disables conversation creation with an explanatory message; see [`assistant.md`](assistant.md) → Configured state), while `token_budget` is the **largest budget over the account's held roles** (`Assistant::Access.effective_budget`); `null` means unlimited. `name` is the instance's assistant display name (`assistant.name` on `core.SystemSettings`, resolved through `AssistantView.display_name` — the file tier always yields a value, default `Assistant`). Protected by `AuthHandler` — returns 401 if the access token is missing or invalid.
- **Apps** — GET, no body. Returns a JSON array of launchable app summaries: `[{"id", "slug", "display_name", "description"?}]`. An app is listed when it is enabled (`status == "active"`) and the active role satisfies every required grant action (`GrantResolver.role_usable?`). The `compatible_roles` field on `app.App` is metadata only and is not consulted. Protected by `AuthHandler` — returns 401 if the access token is missing or invalid.
- **Change password** — POST body: `{"change_token": "...", "old_password": "...", "new_password": "..."}` (bootstrap path) OR `{"old_password": "...", "new_password": "..."}` with a valid `auth_token` (authenticated path). `change_token` is single-use on success.
- **Password reset request** — POST body: `{"email": "..."}`. Always returns `{"ok": true}` — anti-enumeration.
- **Password reset confirm** — POST body: `{"token": "...", "new_password": "...", "cookie": true?}`. Returns `200 {"ok": true}` on an existing credential, the login-shaped token/cookie response on a first credential (operator invite accepted), 401 if token is invalid/expired, 422 on a short password. Under MFA enforcement `always` with an un-enrolled account, a first credential returns `200 {"ok": true}` with no session — the invite is accepted, and the sign-in that follows holds at the enrollment step (B-141).
- **Temporary password** — POST (no body). Gate chain mirrors `mfa/disable`: CSRF check, `AuthHandler`, `provision_credentials` on `iam.Account`, system bypass rejected. Returns `200 {"temporary_password": "K7M4-9XQ2-WBTD-H3PN"}` — the plaintext, revealed exactly once. 422 for a missing account, a service account, or a `suspended`/`disabled` account.
- **Invite** — POST (no body). Same gate chain. Returns `200 {"ok": true, "first_invite": true?}` — `first_invite` is true when the account held no `password` slot before the call. 422 for a missing or service account.
- **Credential states** — GET, repeatable `id` query parameter (`?id=<ulid>&id=<ulid>`). Same gate chain minus the CSRF check (a GET carries no state change). Returns `200 {"states": [{"id", "has_password", "must_change_pw", "mfa_enabled", "invite_pending", "federated"}, …]}`; ids with no live account are skipped.
- **Enroll verify** — POST body: `{"enroll_token": "...", "code": "123456"}`. Public — no session exists yet; the one-shot enroll token is the authorization. CSRF-checked like every state-changing route. The request body has no `cookie` field — the response follows the cookie mode of the login that created the enroll token (the token stores it). Returns the same two shapes as the login response on success, plus `"backup_codes"` — the raw single-use codes minted by the enrollment, shown exactly once. The session-based enable (`POST /Api/iam/mfa/totp/verify`) returns `{"ok": true, "mfa_enabled": true, "backup_codes": [...]}` with the same one-time codes.
- **Keys** — authenticated by `AuthHandler` (session JWT or `Authorization: Bearer fct_…`). Self-service only: the account id comes from the auth context, never from the URL. Create body: `{"name": "ci-pipeline", "role": "iam.Roles.admin", "expires_at": "2026-12-31T23:59:59Z"?}` — `expires_at` must be a future ISO-8601 datetime (normalized to UTC) and `name` is capped at 100 characters. Create returns `{"id", "key", "display_prefix", "expires_at"}` where `key` is the raw token, shown exactly once. List returns id, name, display_prefix, role_id, created_at, expires_at, last_used_at, revoked_at per key. Revoke is idempotent; a missing or foreign key is a non-disclosing 404. Lifecycle events `api_key_created` / `api_key_revoked` go to the LoginEvent audit log; there is no per-request event (per-mutation attribution lives in `mutations.api_key`).

**Shared response fields:** Every successful login, refresh, challenge, and `/me` response includes `expires_at` (Unix timestamp when the access token expires), `available_roles` (the account's assigned role ids), and `permissions` (the role's permission manifest) so the frontend can track token freshness, list switchable roles, and build a RBAC-filtered sidebar without extra round-trips. The `scopes` field (per-(doctype, action) scope aliases) is included alongside `permissions` whenever the role has at least one permission line — it gives the frontend the same scope information the Lua `export.create(ctx)` hook uses via `ctx.actor.scope`.

**Permission manifest:** `IAM::Helpers.build_permission_manifest` folds the role's permission lines into two maps (pure function of the role content — no DB access; both fields are nil when the role has no permissions):

- **`permissions`** — one key per distinct normalized `on` path (`crm.Deal`; a bare `Account` normalizes to `iam.Account`), value = the deduped action list. A domain-wide line (`on` with no dot and a lower_case domain, e.g. `hr`) is emitted under the domain-wildcard key `hr.*` — the frontend matcher grants every doctype in the domain through it. A wildcard line keeps its aggregated action list on the literal key `"*.*"`. Wildcard lines that carry `except` carve-outs fold per action under reserved keys `"*.*.except.<action>"` (e.g. `"*.*.except.create"`) — the intersection of that action's wildcard lines' except lists, deduped, first-seen order preserved. A key is emitted only when its fold is non-empty; a doctype key can never contain `*`, so no collision is possible.
- **Per-action fold.** Wildcard lines may except different paths per action (the seeded `editor` creates `core.Webhook` through its wildcard line but reads/edits/deletes only its own — the B-76 arbitration). The per-action fold keeps every key faithful to the backend's OR-over-lines semantics: a doctype is excepted for an action only when every same-action wildcard line subtracts it. The pre-B-85 shape (one union key) hid grants in this role shape — the editor's Webhook create button never rendered although the API served the create. Residual limit: same-action lines whose except entries interact through prefix matching (one line excepts `core.DocType`, another `core.DocType.Comment`) cannot be expressed exactly as one path list; the fold then under-subtracts and the frontend may show an affordance the wildcard fallback would deny. No seeded role uses that shape.
- **`scopes`** — per-(doctype, action) scope-alias union with the same rules as the Lua `ctx.actor.scope`: any unrestricted matching line → `[]`; all matching lines scoped → union of the aliases. Wildcard lines merge under the `"*.*"` scopes key and domain-wide lines under their `"{domain}.*"` key: the frontend consults `scopes["*.*"]` when its wildcard fallback grants the action and `scopes["{domain}.*"]` when a domain-wide grant does (admins are unaffected — they short-circuit on `*.* → "*"` before the scopes lookup). The reserved `"*.*.except.<action>"` permissions keys and the `"*.*"` / `"{domain}.*"` scopes keys never name a doctype; UI consumers must not iterate either map's keys to render one.
- **Matching (frontend side).** The matcher in `frontend/src/lib/permissions.svelte.ts` grants in order: admin short-circuit (`*.* → ["*"]`); exact key; then the domain-wildcard key `"{domain}.*"` (a domain-wide grant makes every doctype in the domain actionable, and is never suppressed by carve-outs); then the wildcard fallback — the `"*.*"` action list grants a doctype that no `"*.*.except.<action>"` entry (for the checked action) equals or prefix-matches (an entry on `core.DocType` also excludes `core.DocType.Comment`). An explicit key grant is never suppressed by the carve-outs. `buildNavModel` reuses the same matcher as a per-doctype visibility predicate.
- **Structural metadata.** A role with no `read` line on `core.DocType` still resolves the definitions of the doctypes it holds any grant on, and the domains it holds grants inside (`RBAC::MetadataGate` — see [`rbac.md`](rbac.md) → Definition and domain visibility). The manifest itself is unchanged; the nav filter keeps intersecting it with the definition registry.
- **Effective manifest (app-scoped callers).** `IAM::Helpers.build_effective_manifest` folds `RBAC::GrantResolver.resolve` output into the same two-map shape (pure function of the resolved scope — no extra DB access; both fields nil when the scope is empty). Keys are concrete `domain.Doctype` paths (the resolver de-wildcards entries against the grant targets), plus the domain-wildcard `domain.*` form when a wildcard grant target collapsed with a wildcard role permission. Per key and granted action, the contributing role lines' `except` paths fold to their intersection (the same OR-over-lines semantics enforcement applies); a fold that covers the key's own path removes the action — the carved doctype does not exist in the manifest — and any other non-empty fold is emitted under the reserved `{key}.except.{action}` key for the client matcher to subtract on descendant targets (the prefix rule of `Permission#matches_except?`). The `scopes` map follows `build_permission_manifest`'s rules per (key, granted action). `@facetapp/sdk`'s `can` / `scopes` helpers match both manifest shapes; the frontend matcher only ever sees the role manifest.

## Configuration

See `config.dev.yml` and `config.test.yml` for defaults. Key settings:

| Key | Default | Description |
|---|---|---|
| `iam.jwt.access_token_ttl` | 900 | JWT access token lifetime (seconds) |
| `iam.jwt.refresh_token_ttl` | 1209600 | Redis session TTL (seconds, default 14 days) |
| `iam.jwt.refresh_grace_window` | 10 | Grace period for parallel refresh (seconds) |
| `iam.mfa.totp.enabled` | `true` | Whether TOTP MFA is available. The login gates and `MFA.setup` read the **effective policy** instead: `iam.mfa.type` on `core.SystemSettings` (this file boolean translates to the type — true → `totp`, false → `none`) through `IAM::Policy` |
| `iam.mfa.totp.window` | 1 | Accepted time steps before/after current (each 30s) |
| `iam.mfa.totp.issuer` | `"Facet"` | Issuer label in `otpauth://` URI |
| `iam.mfa.enforcement` | `"preferred"` | MFA enforcement mode file tier: `preferred` asks but never blocks; `always` holds every un-enrolled login at the enrollment step. Any other value raises at config load. Runtime tier: `iam.mfa.enforcement` on `core.SystemSettings` (`IAM::Policy.mfa_enforcement`) |
| `iam.auth.mode` | `"hybrid"` | Authentication mode file tier: `hybrid` allows password + federated login; `oidc_only` removes the password path — the login route refuses `403` (`password_login_denied` LoginEvent), the password-reset request/confirm and first-credential bootstrap refuse `422`. Any other value raises at config load. Runtime tier: `iam.auth.mode` on `core.SystemSettings`; saving `oidc_only` there requires one enabled `iam.OIDCProvider`. Recovery: `facet auth:mode hybrid` — the command publishes its settings fanout on exit, and the policy gates read the document row directly, so the mode is live on every server without a restart |
| `iam.change_password_expiration` | 86400 | Credential-token TTL file tier: the password-change / password-reset / invite-link tokens live this long (seconds, default 24h). Runtime tier: `iam.change_password_expiration` on `core.SystemSettings` (`IAM::Policy.change_password_expiration`) — the security gates read the document row directly, so a save applies to every token minted afterwards; tokens already sent keep the window they were minted with. The write gate refuses a value below 1 second |
| `iam.oidc.*` | — | Inbound federated login. Documented in [`oidc.md`](oidc.md) → Configuration |
| `mail.adapter` | `"dev"` | Carbon adapter name. In-box: `"dev"` (stdout) or `"smtp"` (real SMTP). Custom adapters can be registered at startup via `EmailAdapterRegistry.register`. |
| `mail.from_address` | `"no-reply@facet.local"` | From address on outbound email |
| `mail.from_name` | `"Facet"` | From display name |
| `mail.smtp.host` | `"localhost"` | SMTP host (only used when `adapter: smtp`) |
| `mail.smtp.port` | `587` | SMTP port |
| `mail.smtp.username` | `nil` | SMTP username (optional) |
| `mail.smtp.password` | `nil` | SMTP password (optional) |
| `mail.smtp.use_tls` | `true` | Whether to use TLS for SMTP |