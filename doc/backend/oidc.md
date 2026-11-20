# Inbound OIDC — federated login

**Files:** `src/iam/oidc/`, with touch points in `src/http/auth_handler.cr` (public prefix rule), `src/http/server.cr` (route registration), `src/iam/routes.cr` (public providers route), `src/iam/config.cr` (`iam.auth.mode` parse), and `data/seeds/iam.Account/definition.yml` (`federated_identities` field)

Inbound OIDC lets accounts log in through an external identity provider (IdP). The server acts as the OIDC relying party: it starts an authorization-code flow with PKCE, verifies the IdP's `id_token`, and either logs into an existing `iam.Account`, links the identity to one, or creates a new account (JIT provisioning). There is no client library — the flow is hand-rolled on the `jwt` shard and `HTTP::Client`.

The storage principle is fixed: **only secret data lives outside the doctype system.** An identity link is not a secret, so links are ordinary event-sourced document data on the account.

---

## Source files

| File | Role |
|---|---|
| `src/iam/oidc/providers.cr` | `OIDC::Providers` — provider registry backed by `iam.OIDCProvider` documents through the store |
| `src/iam/oidc/provider_store.cr` | `OIDC::ProviderStore` — document-backed enabled-provider list cache (`PassThrough` / `ProcessCache`), the `IAM::RoleStore` shape |
| `src/event/subscriber/oidc_provider_cache.cr` | fanout subscriber — clears the provider list on `fanout:iam.OIDCProvider:*` |
| `data/seeds/iam.OIDCProvider/` | the doctype seed bundle (definition + Lua hooks) |
| `src/iam/oidc/discovery.cr` | `OIDC::Discovery` — discovery document + JWKS cache; `OIDC::Fetcher` — the single injectable HTTP entry point |
| `src/iam/oidc/verify.cr` | `OIDC::Verify` — `id_token` verification (algorithm pinning, JWK→PEM, claim checks) |
| `src/iam/oidc/identity.cr` | `OIDC::Identity` — identity resolution, linking, JIT provisioning, session emission |
| `src/iam/oidc/routes.cr` | `OIDC::Routes` — the two browser redirects |
| `src/iam/oidc/state.cr` | `OIDC::State` — one-shot Redis flow state |

---

## HTTP routes

| Method | Path | Auth | Description |
|---|---|---|---|
| `GET` | `/auth/oidc/:provider` | Public (prefix rule) | Starts the flow: stores state + nonce + PKCE verifier, redirects 302 to the IdP's authorization endpoint |
| `GET` | `/auth/oidc/:provider/callback` | Public (prefix rule) | Consumes the state, exchanges the code, verifies the `id_token`, resolves the identity. Success: session cookies + redirect to `/`. Every denial: redirect to `/Login?error=oidc_denied` |
| `GET` | `/Api/iam/oidc/providers` | Public (exact entry) | The one pre-auth read the login page needs: `{"auth_mode": "hybrid\|oidc_only", "providers": [{"name", "label"}]}`. Issuer, client id, and secret never leave the server |

The `/auth/oidc/` prefix is public because both routes are GET redirects that authorize through the one-shot Redis state row, not through a session. An unknown provider name and a disabled subsystem deny identically — the browser cannot tell them apart.

---

## Configuration — the `iam.OIDCProvider` doctype

Identity providers are **documents**, not config: one `iam.OIDCProvider`
per IdP, managed in the UI (`/Configure/platform/oidc`) and through the
standard document routes. Create, update, and delete run the doctype's Lua
hooks inside the standard pipeline, so provider changes are event-sourced,
audited, and rollback-able. A fresh install seeds no providers, so SSO
stays off until an admin configures one.

| Field | Type | Rules |
|---|---|---|
| `name` | string, required, `unique: true` | URL segment in `/auth/oidc/{name}`. Lua: `[a-z0-9-]+`; immutable after create (the update hook rejects `patch.name`). The create hook refuses a name a tombstoned provider still holds — accounts keep links under the name, and a re-creation against a different issuer would re-authenticate them. |
| `label` | string | Display name. Create hook defaults it to `name`. |
| `issuer` | string, required | Lua via `util.valid_issuer_url`: absolute https URL, or plain http on a loopback host (`localhost`, `*.localhost`, `127.0.0.1`, `::1`) — the dev/e2e mock-IdP carve-out (B-329). |
| `client_id` | string, required | OIDC client id at the IdP. |
| `client_secret` | `secret`, mode `sealed`, required | Top-level field. Staged through `POST /Api/secrets/stage`, adopted in the mutation; content carries only the marker. Revealed once per token exchange (`Secrets.reveal` against `iam.OIDCProvider.{id}`); never in `search` or `display_name`. A missing or unreadable slot denies the login (fail closed). |
| `domains` | array of string | Email-domain allowlist. Lua: lowercase, non-empty entries. Empty = link-based login only. |
| `default_role` | reference → `iam.Roles` | Role for JIT-provisioned accounts of this provider. Optional: when absent, provisioned accounts receive the instance-wide `iam.oidc.provision_roles` baseline (`core.SystemSettings`); with neither, JIT provisioning denies. Applies at creation only. |
| `auto_provision` | boolean, default `false` | |
| `scopes` | array of string | Create hook defaults to `[openid, email, profile]` when absent. |
| `enabled` | boolean, default `true` | Per-provider switch. The registry and the login-page listing serve enabled providers only. |

The registry reads documents through `OIDC::ProviderStore`
(`src/iam/oidc/provider_store.cr`) — a document-backed process cache in
the `IAM::RoleStore` shape. The cache holds the whole enabled-provider
list under one key; the `OidcProviderCache` Pub/Sub subscriber clears it
on every `fanout:iam.OIDCProvider:*` fanout, and `cache.staleness_ttl_s`
bounds the lost-fanout case. Tombstones are excluded from every read.

There is no global kill switch: the per-provider `enabled` field is the
only switch. An operator who wants SSO off disables every provider.

The **authentication mode** (`hybrid` \| `oidc_only`) is a runtime setting
(`iam.auth.mode` on `core.SystemSettings`, file fallback `iam.auth.mode`).
Under `oidc_only` the login route refuses with `403` (plus a
`password_login_denied` LoginEvent), and the password-reset and
first-credential routes refuse with `422`. The write gate refuses a save
that sets `oidc_only` while no enabled provider document exists. Recovery
for a lockout (IdP dead, no session): `facet auth:mode hybrid` pins the
mode on the settings document with the system principal.

**Load-time validation (fail closed)** lives in the Lua hooks now — a
malformed provider answers `422` at save time:

- `name` must match `[a-z0-9-]+` (it appears in URLs) and must be unique
  among live rows **and** tombstones.
- `issuer` must be an absolute https URL with a host, or plain `http` on a
  loopback host (`localhost`, `*.localhost`, `127.0.0.1`, `::1`) —
  `util.valid_issuer_url`. The loopback carve-out is the dev/e2e mock-IdP
  escape: a plain-http IdP never leaves the machine, so no TLS is needed
  there (B-329).
- `domains` / `scopes` entries must be non-empty strings; domains
  lowercase at write time.

There is no save-time coupling between `auto_provision` and `default_role`:
the role set resolves at login time (provider role, else the instance
baseline), and a provider with neither denies JIT provisioning with a
clear audit reason.

---

## The `federated_identities` field

Links live on the `iam.Account` document — no side table, no migration.

```yaml
federated_identities:
  type: array
  filters: [membership]   # creates the gin_jsonb index on content->'federated_identities'
  items:
    type: object
    properties:
      provider:  { type: string,   required: true }
      subject:   { type: string,   required: true }
      linked_at: { type: datetime, required: true }
```

- **The join key is `(provider, subject)` — never email.** An IdP email change can never silently take over an account.
- Each login adds no per-link `last_login_at` — the `oidc_login` audit event records each login with a timestamp.
- The link history is event-sourced: linking and unlinking are ordinary mutations, auditable and rollback-able.
- The `filters: [membership]` declaration makes `Index::Manager` create a `gin_jsonb` index on `content->'federated_identities'` (see [`index-management.md`](index-management.md)). That index serves the containment lookup in the resolution's first step.

---

## Login flow

1. **Start (`GET /auth/oidc/:provider`).** The route fetches the IdP's discovery document, generates `state` and `nonce` (64 hex chars each) and a PKCE verifier (64 URL-safe chars), stores them as one JSON string under `oidc:state:{state}` with a 300 s TTL, and redirects to the authorization endpoint with `response_type=code`, `client_id`, `redirect_uri` (`{scheme_base_url}/auth/oidc/{provider}/callback`), `scope`, `state`, `nonce`, `code_challenge` (S256), and `code_challenge_method=S256`.
2. **Callback (`GET /auth/oidc/:provider/callback`).** The state row is consumed with `GETDEL` before any processing — a missing, expired, or already-consumed state denies. The code is exchanged at the token endpoint (PKCE verifier attached, client secret in an HTTP Basic header), the `id_token` is verified, and `Identity.authenticate` resolves the identity.

```crystal
# Route level — the flow is HTTP-driven; services compose under it:
#   State.create / State.consume  — one-shot flow state (Redis)
#   Discovery.endpoints / keys    — cached IdP metadata
#   Verify.call(token, provider, nonce)     # => payload Hash | raises Error
#   Identity.authenticate(db, provider, claims)
#     # => TokenEmitter::Result | ServiceError
```

---

## Identity resolution

`Identity.resolve` runs four steps in order. The lookup for step 1 is one containment query over the account projections, served by the GIN index:

```sql
SELECT id, content->>'status', content->>'email', content->>'name',
       content->'roles', content->>'default_role'
FROM projections
WHERE domain = 'iam' AND doc_type = 'Account' AND deleted_at IS NULL
  AND content->'federated_identities' @> $1::jsonb
```

with `$1` = `[{"provider": "…", "subject": "…"}]`.

| Step | Condition | Outcome |
|---|---|---|
| 1 | Exactly one account holds `(provider, subject)` | `suspended` / `disabled` reject; otherwise login (no new link) |
| 2 | Email match + `email_verified: true` + domain in `provider.domains` | `suspended` / `disabled` reject (no duplicate account); the link is appended via `Document::Update` (system principal `system:oidc`, idempotent — an existing identical link is left untouched), then login |
| 3 | Unknown identity + unknown email + verified email + allowed domain + `auto_provision` | Account created via `Document::Create` (system principal), then login |
| 4 | Everything else | `oidc_denied` audit event, generic browser error |

Step 2 also rejects service accounts — a machine identity must not federate.

**JIT roles.** The provisioned account's role set resolves in two steps:
the provider's `default_role` when set, else the instance-wide
`iam.oidc.provision_roles` baseline on `core.SystemSettings` (read
uncached through `IAM::Policy.provision_roles`). With neither, step 3
denies. The first resolved role doubles as the account's `default_role`.

**JIT content.** A provisioned account carries `email`, `name` (from the OIDC `name` claim, else the email), `status: "active"`, `roles` (the resolved list), `default_role`, `organizational_unit: "/"`, and one `federated_identities` entry. The account's document id is the lowercased email (the named-id branch in `Document::Create.resolve_doc_id`). Later role changes are ordinary account edits and never drift back.

**Pending bootstrap.** A `pending` account that completes an OIDC login flips to `active` through `AccountPatch` before the session is emitted (the flip is idempotent).

**No local MFA check.** The OIDC path does not consult `mfa_enabled` — the IdP is the factor of record.

**Race handling.**

- A unique-violation on the account email during JIT means a concurrent callback won — the service re-runs the resolution from step 1 instead of creating a duplicate. A second consecutive collision denies (corrupted state, not a race). The email unique index, the email-derived document id (a `409` from the named-id branch), and the database-level unique constraint all surface into this path.
- The `(provider, sub)` double-link race cannot create a second account: the email unique constraint backstops JIT, and step 1 absorbs the link-before-write case.
- If the step-1 lookup ever returns more than one account, the login denies defensively and writes an audit event — corrupted state, never a guess.

---

## Security properties

| Property | Mechanism |
|---|---|
| Algorithm pinning | The token header never selects the algorithm. `alg` must be `RS256` or `ES256`; `none` and every HMAC variant reject before any key is touched. The selected JWK's `kty` must match (`RSA` for RS256, EC `P-256` for ES256) — this closes algorithm-confusion. |
| PKCE | S256 challenge at start; the verifier rides in the token exchange. The server never stores a challenge in a URL. |
| One-shot state | Stored under `oidc:state:{state}` as a JSON string, consumed atomically with `GETDEL`, 300 s TTL. A crash after consume invalidates the flow; it never allows a replay. |
| Nonce | Generated per start, stored in the state row, checked against the `id_token` with a constant-time compare. |
| Discovery / JWKS cache | Fetched once per issuer, 300 s TTL. An unknown `kid` (key rotation) triggers exactly one forced JWKS refresh, then re-verification. |
| Injectable fetcher | All IdP HTTP goes through one function (`OIDC::Fetcher.call`); production uses a 5 s-timeout `HTTP::Client`, specs replace the proc. Failures degrade to a non-200 result and deny. |
| Anti-enumeration | One generic browser error (`/Login?error=oidc_denied`). The denial reason lands only in the audit log. |
| Confidential client | The client secret rides only in the HTTP Basic header of the token exchange — never in a URL, never in the audit log. |
| Session mode | Cookie mode only (`TokenEmitter.set_cookies`), like password login. |

---

## Audit events

All three land in `iam.LoginEvent` (see [`iam.md`](iam.md)). The `details` field never carries secret material — no tokens, no codes, no verifier.

| Event | Written when |
|---|---|
| `oidc_provisioned` | A JIT account was created (before `oidc_login`) |
| `oidc_login` | An OIDC login emitted a session |
| `oidc_denied` | Any denial: verification failure, bad state, denied resolution, defensive multi-match, session-emit failure. The `details` field carries the machine-readable reason |