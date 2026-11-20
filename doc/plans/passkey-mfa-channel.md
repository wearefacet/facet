# Plan — Passkey as an MFA channel (WebAuthn)

Status: **draft — feasibility study. Awaiting decisions (§8). No code
written.** Verified against the tree on 2026-11-11. This plan extends
[`../backend/iam.md`](../backend/iam.md) (MFA, Enroll, BackupCodes sections).

---

## 1. Summary

The instance supports one MFA factor today: TOTP. The effective policy reads
`iam.mfa.type = none | totp`. This plan studies a second factor kind: the
**passkey** (WebAuthn). An account enrolls a device. At login, the device
signs a server challenge. The server stores only a public key.

The study finds no architectural blocker:

- The factor grammar is already open. The `core.SystemSettings` seed says:
  "The factor type grammar stays open for future factor kinds (WebAuthn, ...)"
  (`data/seeds/core.SystemSettings/definition.yml`).
- `GET /Api/iam/me` already returns `mfa_type` (`src/iam/routes.cr`).
- The challenge route already dispatches on `method` (`totp`, `backup_code`),
  so a third method is an extension, not a redesign.
- Backup codes, the lockout path, and the audit log are factor-agnostic.
- A MIT-licensed Crystal relying-party shard exists (§4.6).

Five decisions are open (§8). Implementation starts after a decision on each.

## 2. Current state (TOTP)

| Concern | Today | Where |
|---|---|---|
| Policy read point | `Policy.mfa_type` — `core.SystemSettings` row, file fallback | `src/iam/policy.cr` |
| Factor secret | TOTP seed in the sealed `mfa` secrets slot of the account | `src/iam/mfa.cr`, `src/secrets/store.cr` |
| Enrolled flag | `mfa_enabled` document field, flipped through `AccountPatch` | `src/iam/account_patch.cr` |
| Login gate | challenge hash in Redis, attempt counter, lockout | `src/iam/login.cr`, `src/iam/challenge.cr` |
| Replay guard | `auth_state.last_totp_step`, atomic conditional advance | `src/iam/auth_state.cr` |
| Recovery | single-use backup codes, SHA-256 digests in `mfa_backup_codes` | `src/iam/backup_codes.cr` |
| Enroll at login | `always` enforcement holds the login; response carries secret + `otpauth://` URI | `src/iam/enroll.cr` |
| Admin recovery | `mfa/disable` clears slot, step counter, codes, flag | `src/iam/mfa.cr` |

Login response shape: `{mfa: true, challenge_id, type: "totp"}` — the `type`
string is hardcoded in `src/iam/routes.cr`.

## 3. What a passkey changes

A passkey is a WebAuthn credential. The device holds the private key. The
server holds a public key. Verification checks a signature over a
server-issued challenge, the origin, and the RP ID hash. A stolen credential
table yields no reusable secret. A signature does not verify on another
origin, so a phishing site cannot replay it.

WebAuthn has two usage modes:

1. **Second factor** — password first, then a passkey assertion. This replaces
   TOTP. It is the scope of this plan.
2. **Passwordless** — the passkey replaces the password. This touches the
   whole login pipeline. Out of scope (§11), but the design keeps the door
   open: registration asks for `residentKey: preferred`, so a later
   passwordless login can reuse the same credentials.

A passkey does not use the TOTP replay guard. Replay protection comes from
the single-use server challenge plus the signature counter (§5).

## 4. Design

### 4.1 Policy and configuration

- `Policy::MFA_TYPES` gains `passkey`: `none | totp | passkey`. The instance
  has one active factor type, as today.
- The `core.SystemSettings` seed enum and the write gate gain the value.
- File tier: `iam.mfa.totp.enabled` (a Bool) becomes `iam.mfa.type` (a
  String). The application is in development, so the file grammar can change
  freely. The `totp.window` and `totp.issuer` keys stay. New keys:

```yaml
iam:
  mfa:
    type: totp              # none | totp | passkey
    passkey:
      rp_id: "facet.example.com"   # registrable domain. Permanent choice (§6).
      rp_name: "Facet"
      origins:
        - "https://facet.example.com"
```

- Gate symmetry: the TOTP routes answer `422` when the type is `passkey`; the
  passkey routes answer `422` when the type is `totp`. This mirrors the
  existing `MFA.setup` gate.

### 4.2 Storage

- New table `mfa_passkeys` (migration with `-- UP` / `-- DOWN`). Same
  precedent as `mfa_backup_codes`: a dedicated table outside the event log.
  One account holds many credentials (laptop, phone, security key).

| Column | Type | Notes |
|---|---|---|
| `credential_id` | text, PK | base64url of the raw credential id |
| `account_id` | text, indexed | `iam.Account` ULID |
| `public_key` | text | COSE key, base64 |
| `sign_count` | bigint | clone-detection counter |
| `aaguid` | text | authenticator model id, nullable |
| `transports` | text[] | hint for the browser at assertion time |
| `backup_eligible` | bool | BE flag at last ceremony |
| `backup_state` | bool | BS flag — credential is in synced storage |
| `label` | text | account-chosen name, capped |
| `created_at` / `last_used_at` / `revoked_at` | timestamp | tz-naive UTC |

- Ceremony challenges live in Redis with a short TTL (~2 minutes), single
  use. The login challenge hash carries the assertion challenge; the enroll
  token record carries the registration challenge.
- `auth_state` stays untouched. The TOTP step guard has no passkey role.

### 4.3 API surface

| Method | Path | Authorization | Purpose |
|---|---|---|---|
| `POST` | `/Api/iam/mfa/passkey/register/options` | session | Creation options for `navigator.credentials.create()` |
| `POST` | `/Api/iam/mfa/passkey/register/verify` | session | Verify attestation. Store credential, flip `mfa_enabled`, mint backup codes — same contract as TOTP verify |
| `POST` | `/Api/iam/mfa/passkey/assertion/options` | `challenge_id` from `MFARequired` | Request options for `navigator.credentials.get()` |
| `POST` | `/Api/iam/challenge` | existing | Gains `method: "passkey"`. Body carries credential id + authenticator response |
| `GET` | `/Api/iam/mfa/passkeys` | session | List own credentials — label, flags, dates. Mirrors `/Api/iam/keys` |
| `DELETE` | `/Api/iam/mfa/passkeys/:credential_id` | session, ownership | Revoke one credential. A revoke of the last credential flips `mfa_enabled` to false |

All new routes sit behind the existing CSRF gate (`X-Requested-With`).

### 4.4 Flow changes

- **Login.** The `MFARequired` response returns the effective factor type
  (`totp` | `passkey`) instead of the hardcoded `type: "totp"`.
- **Challenge.** `Challenge.call` gains a `passkey` method branch. The branch
  loads the credential, verifies the assertion, updates the sign count, and
  emits tokens. Failures burn the same challenge attempts and reach the same
  lockout.
- **Backup codes.** `method: "backup_code"` stays, and works with both
  factor types.
- **Enroll at login.** Under `always` enforcement with `type: passkey`, the
  `EnrollmentRequired` body carries `factor: "passkey"` and no secret or URI.
  `POST /Api/iam/mfa/enroll/verify` gains a passkey branch: the body carries
  the attestation; the enroll token record carries the ceremony challenge.
  Limitation: the ceremony needs a browser. A script client cannot complete
  this hold (§6).
- **Disable.** `MFA.disable` also revokes every passkey row of the account.
- **Audit.** New LoginEvent types: `passkey_registered`, `passkey_revoked`.
  The challenge-passed detail names the method.

### 4.5 Frontend

- `frontend/src/lib/loginFlow.ts`: the `mfa_challenge` and `mfa_enroll`
  branches carry the factor type. New decode specs in `loginFlow.spec.ts`.
- New components beside `TotpRegistrationScreen.svelte`: a passkey enrollment
  screen and a passkey challenge step. `navigator.credentials` calls run in
  the browser only — an SSR guard is mandatory.
- Settings → Security: passkey list, add, rename, revoke.
- `SystemSettingsForm.svelte`: the factor-type enum gains `passkey`.

### 4.6 Library

| Option | Assessment |
|---|---|
| `aloli-crystal/webauthn` | MIT. RP-side verification: strict CBOR decoder, COSE keys (ES256 + RS256), registration (attestation `none`), authentication with sign-count check, user verification on by default. Very new (0 stars, 7 commits), but small enough for a full audit. Pin a commit, as `shard.yml` does for `lua.cr` and `agent.cr`. |
| Vendor in-tree | Same code under `src/iam/webauthn/`, MIT attribution. TOTP is vendored (~90 lines), but WebAuthn is 600+ lines with specs. The shard avoids that maintenance load. |
| `renich/crystal-cbor-fido` | **Rejected.** GPL-3. Incompatible with the BUSL-1.1 distribution of this project. |

Recommendation: adopt the shard, pinned to a commit, wrapped in our own spec
suite. Fall back to vendoring if the upstream stalls.

## 5. Security notes

- **User verification required.** Every assertion must carry the UV flag.
  Possession of the device plus the unlock gesture (biometric or PIN) makes
  the passkey a true second factor. The shard enforces this by default.
- **Origin binding.** Every ceremony checks `clientDataJSON.origin` against
  the configured `origins` list.
- **RP ID binding.** Every ceremony checks the RP ID hash prefix of the
  authenticator data.
- **Clone detection.** A non-increasing signature count fails the assertion.
  Authenticators that always send 0 are exempt — the stored count is 0.
- **No duplicate enrollment.** Registration options carry
  `excludeCredentials`, so one authenticator cannot enroll twice.
- **Challenge hygiene.** Server challenges are 32 random bytes, single use,
  short TTL, deleted at verify.
- **Rate limits.** Registration verify reuses the `mfa_verify_attempts`
  counter. Assertion failures reuse the challenge attempt counter and the
  lockout path.

## 6. Risks

- **RP ID is permanent.** A change invalidates every enrolled passkey. Decide
  the value once, before the first enrollment.
- **Secure context.** WebAuthn needs HTTPS, or `localhost`. Development over
  a LAN IP will not run a ceremony. The dev config (`secure_cookies: false`)
  covers only localhost.
- **Enroll-at-login is browser-only.** Under `always` enforcement, a script
  client cannot complete a passkey hold. TOTP was computable by a script, a
  passkey is not. Mitigations: an operator issues a temporary password, or
  the account enrolls through the browser first.
- **Shard maturity.** `aloli-crystal/webauthn` has no community track record.
  Mitigation: our own spec suite over the wrapper, and vendoring as fallback.

## 7. Scope

| Slice | Work |
|---|---|
| Backend | Migration, config records, policy, passkey service + routes, Login / Challenge / Enroll integration, specs. The larger half. |
| Frontend | Login flow branches, two auth screens, settings management UI, settings form enum, stories and specs. |

TOTP, backup codes, lockout, and the audit log stay as they are.

## 8. Discuss-first decisions

1. **Factor model.** Single instance-level type (`none | totp | passkey`), or
   per-account multi-factor (an account enrolls both)? The single type
   matches the current design and the `iam.mfa.type` grammar. Proposal:
   single type.
2. **Library.** Adopt `aloli-crystal/webauthn` pinned to a commit, or vendor
   in-tree? Proposal: adopt the shard.
3. **Phase 1 is second-factor only.** Passwordless login is a later plan that
   reuses the stored credentials. Proposal: agree.
4. **UV required** on every assertion. Proposal: agree (the shard default).
5. **RP ID and origins** for dev and production. Need values from the user.

## 9. Phases

1. **Spike.** Add the shard, pin the commit, compile, run its specs. Confirm
   the API surface against this plan. `make check` green.
2. **Backend core.** Migration, config, policy, the passkey service module,
   unit specs for the wrapper.
3. **Backend flows.** Routes, Login / Challenge / Enroll integration, audit
   events, integration specs (enroll → challenge login, replay rejected,
   clone rejected, policy gates).
4. **Frontend.** Login flow decode, auth screens, settings management,
   stories with a mocked `navigator.credentials`.
5. **Finalize.** Full `make test`, `bin/ameba`, `pnpm check`, docs: extend
   `doc/backend/iam.md` and `doc/frontend/workflow.md`, then retire this plan
   into them.

## 10. Verification gates

- `make check` after each phase.
- New specs: `spec/iam/passkey*_spec.cr` (unit + integration), `loginFlow.spec.ts`
  extensions, story play functions for the two new screens.
- Isolated spec runs during development; `make test` once at finalization
  (`make test_db_up` first).
- Lint: `bin/ameba`, `pnpm check` — clean at the end.

## 11. What this plan will not do

- **Passwordless login.** The passkey does not replace the password in this
  plan (§3, mode 2).
- **Attestation statement verification.** The shard supports attestation
  `none`. The server does not prove the authenticator make or model. This is
  the common relying-party choice and avoids privacy costs.
- **Per-account multi-factor.** Unless decision 1 says otherwise, an account
  holds one factor kind, set by the instance policy.
- **TOTP removal.** TOTP stays a supported factor type.
