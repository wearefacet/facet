# OAuth App Authorization Server

OAuth 2.0 Authorization Code + PKCE flow for Facet-registered applications, with refresh-token rotation and revocation, and optional DPoP sender-constraining (RFC 9449). **Not** a general OAuth provider — the endpoints live under `/OAuth/...` and serve only apps whose definition lives in `app.App` (App System Phases 4 + 5).

## Source Files

| File | Role |
| --- | --- |
| `src/oauth.cr` | Namespace root (requires the modules below) |
| `src/oauth/authorize.cr` | `OAuth::Authorize` — parses/validates params, builds the consent payload, issues authorization codes |
| `src/oauth/client_info.cr` | `OAuth::ClientInfo` — `GET /OAuth/client-info` lookup: app slug → public client metadata (active apps only) |
| `src/oauth/code_store.cr` | `OAuth::CodeStore` — Redis-backed, single-use (Lua `HGETALL`+`DEL`), 60s TTL |
| `src/oauth/redirect_uri.cr` | `OAuth::RedirectUri` — the request-time match: exact plus the `*` loopback-port rule; `valid_shape?` / `https_or_loopback?` delegate to the shared rule in `Util::RedirectUri` |
| `src/oauth/token.cr` | `OAuth::Token` — verifies PKCE, consumes the code, creates an app `RedisSession`, issues the ES256 app JWT |
| `src/oauth/refresh.cr` | `OAuth::Refresh` — rotates an app session's refresh token; binds the grant to the issuing client; enforces the refresh floor (`REFRESH_FLOOR_S`); re-validates live state on every refresh |
| `src/oauth/rate_limiter.cr` | `OAuth::RateLimiter` — sliding-window `(client_id, IP)` rate limit on the token endpoint; counts the `authorization_code` grant only, refresh is exempt. `check_ip` is the per-IP variant for unauthenticated endpoints (registration) |
| `src/oauth/register.cr` | `OAuth::Register` — RFC 7591 dynamic client registration for MCP clients: validates the client metadata, mints a public-client `client_id` |
| `src/oauth/discovery.cr` | `OAuth::Discovery` — `GET /.well-known/oauth-authorization-server` metadata |
| `src/oauth/cors.cr` | `OAuth::Cors` — Kemal handler that mirrors registered `allowed_origins` on `/OAuth/*` and `/Api/*`; the WebSocket route consults the same cache for its `/Ws` origin allowlist |
| `src/oauth/origin_cache.cr` | `OAuth::OriginCache` — process-wide `origin → app_id` cache, lazy rebuild, `mark_stale` on `app.App` mutation events |
| `src/oauth/routes.cr` | `OAuth::Routes` — `get`/`post` route registration on the Kemal router, including dispatch between `authorization_code` and `refresh_token` grant types |
| `src/oauth/dpop.cr` | `OAuth::DPoP` — RFC 9449 proof verification: JOSE header, signature, and the claim contract (`jti`, `htm`, `htu`, `iat`, `ath`) |
| `src/oauth/replay_cache.cr` | `OAuth::ReplayCache` — Redis single-use cache for DPoP `jti` values, keyed `(jkt, jti)`; also hosts `OAuth::HTU`, the configured-origin `htu` reconstruction |
| `src/http/auth_handler.cr` | `AuthHandler` — branches on JWT `typ: "app"` to build an app-scoped `AuthContext`; enforces the DPoP gate on `cnf`-bound tokens |
| `src/iam/jwt.cr` | `IAM::JWT` — gains `APP_TOKEN_TYP = "app"` and `build_app_payload` |
| `src/iam/redis_session.cr` | `IAM::RedisSession` — gains `app` field, `create_app_session`, `delete_app_sessions`, `list_account_app_sessions` (Phase 5). App sessions also store the issuing `client_id` — see [Client binding on app refresh tokens](#client-binding-on-app-refresh-tokens) |
| `src/iam/routes.cr` | `IAM::Routes` — gains the three `/Api/iam/sessions*` revocation endpoints (Phase 5) |
| `src/event/subscriber/app_cache.cr` | `Event::Subscriber::AppCache` — `PSUBSCRIBE fanout:app.App:*` listener that calls `OAuth::OriginCache.mark_stale` |

## Endpoints

| Method + Path | Auth | Purpose |
| --- | --- | --- |
| `GET /OAuth/authorize` | Browser session (cookie or `Authorization: Bearer …`) | Render the consent screen — app metadata + the account's usable roles + the resolved effective scope per role. Never issues a code. **No session → 302 to `/Login?redirectTo=…`** with the original authorize URL embedded; the login flow returns the user here after sign-in. **Browser navigation (`Accept: text/html`) → 302 to `/OAuthConsent?<authorize params>`**, the frontend route that renders the consent UI. **JSON fetch (`Accept: application/json`) → the consent payload** the frontend consumes. |
| `POST /OAuth/authorize` | Browser session | Consent confirm. Body carries the authorize params + the elected `role`. Issues a 60-second single-use authorization code. **No session → 303 to the login page** (same `redirectTo` embedding — 303 so the browser re-issues a GET, never a POST, at the login URL). |
| `POST /OAuth/token` | Public (PKCE-protected) | Token endpoint. `grant_type=authorization_code`: verifies PKCE, consumes the code, returns the app JWT — counted by `OAuth::RateLimiter`. `grant_type=refresh_token`: rotates the app (or MCP) session — exempt from the counter, guarded by the refresh floor. The app path must also present the `client_id` bound at issuance (see [Client binding on app refresh tokens](#client-binding-on-app-refresh-tokens)). Both return the same body shape: `access_token`, `token_type`, `expires_in`, `refresh_token`. `token_type` is `"DPoP"` when the request carried a verified `DPoP` proof, `"Bearer"` otherwise (see [DPoP sender-constrained tokens](#dpop-sender-constrained-tokens-rfc-9449)). No `scope` member — the server advertises no scope vocabulary (`scopes_supported: []`), so the optional member is omitted (RFC 6749 §5.1); a non-string `scope` breaks spec-compliant clients (opencode, the MCP SDK). |
| `POST /OAuth/register` | Public (`AuthHandler::PUBLIC_ROUTES`) | RFC 7591 dynamic client registration for MCP clients. Validates the client-metadata JSON, mints an opaque public-client `client_id`. Rate limited per IP. No record is kept — see [Dynamic client registration](#dynamic-client-registration). |
| `GET /OAuth/client-info?slug=…` | Public (`AuthHandler::PUBLIC_ROUTES`) | Client metadata for first-party CLI clients — the CLI resolves its `client_id` by app slug before it starts the PKCE flow. Active apps only; every failure path returns `404 {"error": "unknown_client"}`. |
| `GET /.well-known/oauth-authorization-server` | Public | Discovery metadata for off-the-shelf OAuth client libraries. |

### Login redirect contract

The unauthenticated bounce is a **relative** `Location: /Login?redirectTo=<encoded authorize URL>` — same-origin by construction. The backend never names the frontend's address: in dev the Caddy proxy (`caddy/Caddyfile`) serves both surfaces on one origin, and in production a reverse proxy does the same. No `frontend_url` config key exists.

The embedded target is guarded by `OAuth::Routes.safe_return_to?`: only a path-absolute URL whose path is exactly `/OAuth/authorize` is accepted. Scheme-relative (`//host`), absolute URLs to any origin, other paths, and control characters are rejected with `400` — no open redirect. The guard is a backstop: the target is built from the request itself today, but the contract is pinned so a future change sourcing the target from client input cannot silently open a redirect hole.

The frontend login page consumes the `redirectTo` param (see `frontend/src/hooks.server.ts` → `buildLoginRedirect` and `routes/Login/+page.svelte`): after sign-in it navigates back to the authorize URL, and the consent flow proceeds normally.

### Consent hand-off contract

An authenticated browser navigation to `GET /OAuth/authorize` is handed to the frontend consent route. The backend content-negotiates on `Accept`:

- **`Accept: text/html`** (browser navigation) → `302 Location: /OAuthConsent?<authorize params>`. The redirect is **relative** and same-origin by construction, mirroring the `/Login` bounce — the backend never names the frontend's address.
- **`Accept: application/json`** (the frontend's own fetch) → the consent JSON payload, unchanged.

`/OAuthConsent` is a SvelteKit route (`frontend/src/routes/OAuthConsent/`). Its `+page.ts` re-fetches `GET /OAuth/authorize` with the same query and `Accept: application/json`, then renders `ConsentScreen`. On Authorize it POSTs the elected role back to `/OAuth/authorize` and follows the returned `redirect_uri?code=…&state=…` so the OAuth client receives the code. The route uses an uppercase first segment, so it does not collide with the lowercase domain space, and Caddy's `/OAuth/* → backend` rule does not intercept it because the SPA path is one word (`/OAuthConsent`), not the `/OAuth/` prefix.

**Field naming asymmetry:** the consent JSON payload lists each electable role under `role_id` (the qualified `iam.Roles.<name>` reference), while the confirm POST carries the election in a `role` field — with the same qualified value. A wrong or malformed value answers an `access_denied` redirect — the shape is correct, but a hand-rolled client must POST `role: "iam.Roles.admin"`, not `role_id`.

### Client-info endpoint

`GET /OAuth/client-info?slug=…` (`OAuth::ClientInfo`) answers the question a first-party CLI must resolve before it can start the PKCE flow: which `client_id` belongs to the app registered under this slug. The lookup is a live `app.App` projection read by `content->>'slug'` (tombstones excluded). Only an app whose `status == "active"` **and** whose content carries a non-empty `client_id` resolves; the response is `{slug, client_id, name, client_type}` with `name` sourced from the app's `name` field.

Every other path — unknown slug, missing `slug` param, draft or disabled app, content without `client_id` — returns the identical `404 {"error": "unknown_client"}` body. The endpoint therefore never discloses the existence of a non-active registration.

### Dynamic client registration

`POST /OAuth/register` (`OAuth::Register`) implements RFC 7591. The MCP authorization spec requires an MCP client to self-register before it starts the PKCE flow, and discovery advertises the endpoint as `registration_endpoint` — without that member a spec-compliant client stops at discovery. The endpoint answers without a session, an app registration, or a DB connection.

**Stateless by decision.** The registration keeps no record. The MCP branch of `Authorize` / `Token` treats `client_id` as an opaque string bound to the authorization code (MCP is not an app — no `app.App` row, no `GrantResolver`), so the consent screen, PKCE, and the code's `client_id` / `redirect_uri` bindings carry the security. A persisted registry would buy a client name on the consent screen and a revocation list, at the cost of spam management; revisit if consent-screen identity matters.

**Redirect shape re-checked (S7).** The MCP branch has no `app.App` registered list to match against, so the shape rule is the whole admission rule. `Authorize.validate_mcp_redirect_uri` re-runs it at consent (`build_mcp_consent`) and again at code issue (`issue_mcp_code`): `https` on any host, `http` on a loopback host only, no fragment, userinfo, or query. A violation raises `InvalidRequest` — a JSON request error, never a redirect. Residual risk: the shape rule does not bind the redirect URI to the client (no client record exists); PKCE (S256) is the binding that stops code theft in that case.

The contract:

- **Request** — a JSON client-metadata document (RFC 7591 §2). `redirect_uris` is required; every entry must pass the shared shape rule (`Util::RedirectUri.valid_shape?`, through `RedirectUri.valid_shape?`): `https` on any host, or `http` on a loopback host only (`localhost`, any `*.localhost` subdomain, `127.0.0.1`, `::1`), the `*` loopback-port form included. `token_endpoint_auth_method` must be `none` when present. `grant_types` / `response_types` must sit inside the supported set. Unknown members are ignored.
- **Response** — `201` with `client_id` (`Random::Secure.urlsafe_base64(32)`), `client_id_issued_at`, the echoed `redirect_uris`, `token_endpoint_auth_method: "none"`, the supported `grant_types` / `response_types`, and `client_name` when provided. No `client_secret` — public clients only.
- **Errors** — RFC 7591 §3.2.2: `invalid_redirect_uri` for an unusable redirect entry, `invalid_client_metadata` for every other violation, rendered through the shared RFC 6749 §5.2 error body.
- **Rate limit** — `OAuth::RateLimiter.check_ip` counts registrations per IP (scope `register`), same window and cap as the token counter. Behind a reverse proxy every caller shares the proxy's remote address, so one bucket serves the whole proxy; a registration is a rare, human-paced event, and the counter bounds request pressure only.

CORS on the endpoint mirrors the token endpoint: the request `Origin` must be registered on some `app.App.allowed_origins`. A web-hosted MCP client has no registered origin and is not a supported client shape; native clients (opencode, MCP Inspector) make no CORS check.

### Refresh floor and rate-limit scope

The token endpoint serves two grants with different pacing, so each gets its own guard:

- **`authorization_code` — rate-limited.** `OAuth::RateLimiter` counts exchanges per `(client_id, IP)` in a 5-minute sliding window (cap 30). An exchange is a one-shot, interactive event an abuser can hammer. The registration endpoint uses the same window and cap through the per-IP `check_ip` variant. The `IP` in both keys is the resolved client IP (`Util::ClientIp`, see [`util-client-ip.md`](util-client-ip.md)) — the socket host, or the `X-Forwarded-For` hop the routes trust when the peer is a configured trusted proxy. Behind a proxy that is not on `trusted_proxies`, every caller shares the proxy address and funnels into one bucket.
- **`refresh_token` — floor-guarded, exempt from the counter.** Refresh runs on a clock: CLIs and agents renew on a schedule. Counting refreshes would starve long-lived sessions and burst a legitimate client the moment its access token expires.

The floor: `OAuth::Refresh` rejects a refresh presented sooner than `REFRESH_FLOOR_S = 10` seconds after the session's current refresh token was issued, with `429 {"error": "slow_down"}`. The client backs off and retries. The stamp lives on the session — `IAM::RedisSession.refresh_issued_at`, written at session creation and re-written at every rotation. A missing or unparseable stamp fails open.

The floor applies on both refresh paths — the app path (`Refresh.call`) and the MCP path (`Refresh.call_mcp`). It is a pacing guard, not a revocation: the session survives a `slow_down`, and rotation + reuse detection + live-state re-validation stay the enforcement points.

**App sessions refresh only here (S2).** An app-scoped session refreshes through `OAuth::Refresh`, never through `POST /Api/iam/refresh`. The IAM route refuses a session whose `app` field is set with `403` before any rotation, because it would mint the account's whole role instead of the app ceiling (grant ∩ role). `OAuth::Refresh` pins the role and re-validates the grant on every refresh, so the app reach stays bounded.

### Client binding on app refresh tokens

An app refresh token is redeemable only by the client that exchanged the code. `OAuth::Token.call` stores the verified `client_id` on the app session — `IAM::RedisSession.create_app_session` takes it as a required parameter and writes the `client_id` hash field; the `Session` record carries it. The `refresh_token` grant must present the same value:

- **Missing `client_id`** — `401 {"error": "invalid_grant", "error_description": "Missing 'client_id'"}`.
- **A different `client_id`** — `401 {"error": "invalid_grant", "error_description": "Refresh token is not bound to this client"}`.

The binding check runs before the refresh floor and before reuse detection. A wrong-client attempt therefore never revokes the session it names: the check answers `401` and the session stays live — a correct-client refresh right after succeeds. Reuse detection stays reserved for a presented `refresh_id` that matches neither the current nor the previous value.

The MCP refresh path (`Refresh.call_mcp`) has no client binding — MCP client registration is stateless, so no stable `client_id` exists to bind. Browser sessions carry an empty `client_id`; their refresh path (`IAM::Refresh`) never consults it.

## App JWT claims

The token endpoint signs an ES256 JWT (same backing key as the browser-session access token). Claims:

| Claim | Value |
| --- | --- |
| `sub` | The account id (ULID) |
| `sid` | A fresh opaque id — not a `RedisSession` session id. App sessions are independent from the browser session that authorized them. |
| `role` | The elected role name (a real `iam.Roles.name`), unmodified |
| `app` | The `app.App` projection id |
| `typ` | `"app"` (vs `"access"` for browser-session tokens) |
| `cnf` | Present only on a DPoP-bound token: `{"jkt": "<RFC 7638 thumbprint of the proof's P-256 public JWK>"}` (RFC 7800) |
| `iat`, `exp`, `jti` | Standard JWT bookkeeping; TTL is `iam.jwt.access_token_ttl` (default `900` seconds) |

The token response carries that TTL as `expires_in` (`Token::Issued#expires_in`,
`Refresh::Issued#expires_in` — both read `IAM::JWT::ACCESS_TOKEN_EXP`, the
same `iam.jwt.access_token_ttl` value that sets `exp`). The value is a
number, not a string. The access token is not renewed: the client refreshes
before `expires_in` elapses, or the next API call answers `401`.

On every protected API request, `AuthHandler` reads the `app` claim, re-loads the `app.App` projection (gates on `status == "active"`), resolves the grant through `GrantResolver.resolve`, and constructs an `AuthContext.app_scoped`. The grant is **never** cached on the token; it is re-resolved from live `app.App` content so a grant change takes effect immediately for the next request — no token re-issuance needed.

## DPoP sender-constrained tokens (RFC 9449)

The token endpoint sender-constrains the issued JWT when the client presents a DPoP proof. The proof binds the token to one asymmetric key: stolen token bytes alone cannot call the API — the thief also needs the private key, and every API call additionally proves possession with a fresh, single-use proof JWT. Presenting a proof is **optional** at issuance (a proof-less exchange yields a plain bearer token), but a bound token **fails closed** at the API: `Authorization: Bearer …`, a missing proof, or a wrong proof all answer `401`. The scheme gate is symmetric (B-338): an unbound token presented under the `DPoP` scheme answers `401` too — the token is a bearer token, and the server challenges with `WWW-Authenticate: Bearer` so the client corrects its scheme.

### Issuance — proof at the token endpoint

Send the proof in a `DPoP` header on `POST /OAuth/token` (CORS declares the header). The proof is an ES256 JWT:

- **JOSE header** — `typ: "dpop+jwt"`, `alg: "ES256"`, `jwk`: the **public** P-256 EC key as a JWK. Members of the private JWK form (`d`, and other secret material) make the proof invalid.
- **Payload** — `jti` (non-empty random value), `htm: "POST"`, `htu` (the token URL — see [`htu` pinning](#htu-is-pinned-to-the-configured-origin) below), `iat` (unix seconds). No `ath` — the access token does not exist yet, and a proof that carries one is rejected.

On success the response carries `token_type: "DPoP"` and the access token embeds `cnf.jkt` (the RFC 7638 thumbprint of the proof's key). The session stores the same thumbprint, so **every refresh of a bound session requires a fresh proof with the same key** (`htm: "POST"`, the token URL, `iat`, `jti`; still no `ath`). A refresh without a proof, with a different key, or with a replayed proof revokes the session and answers `invalid_grant`.

A failed proof at the token endpoint answers `400` with the RFC 6749 §5.2 body and issues nothing: `invalid_dpop_proof` for structural/signature failures (malformed JWT, wrong `alg`/`typ`, bad signature), `private_key_in_jwk` when the proof's `jwk` header carries private key material (a `d` member or another private-key member), `invalid_claim` for payload violations (`jti`/`htm`/`htu`/`iat`/`ath`) — e.g. `400 {"error": "invalid_claim", "error_description": "DPoP htu mismatch: expected …, got …"}`. RFC 9449 names `invalid_dpop_proof` as the general failure code for an unacceptable proof; this server emits the more specific `private_key_in_jwk` for that one failure.

The token endpoint verifies the proof before it consumes the authorization code. A failed proof does not consume the code — the client can correct the proof and exchange the same code again. A `client_id`, `redirect_uri`, or PKCE mismatch still consumes the code (deliberate anti-phish defense). A proof that fails verification never reaches the replay cache, so a corrected retry may reuse the same `jti`.

**Browser (SPA) clients: the DPoP key must stay alive across the redirect round trip** — `/Login` → `/consent` → the callback. The client generates the key before the bounce and must keep it (a `sessionStorage` JWK or an equivalent). A lost key gives a `401` with no hint.

### Presentation — proof on every API call

A bound token must ride the `Authorization: DPoP <access_token>` scheme, with a fresh proof JWT in the `DPoP` header on **every** request:

- **Payload** — `jti` (new value per request), `htm` (the request method, uppercase), `htu` (the configured origin plus the request path — no query, no fragment; see below), `iat`, and `ath`: `base64url(SHA-256(access_token))` (RFC 9449 §7). `ath` is **required** on API calls; the server recomputes it from the presented token and compares.
- `jti` values are single-use. The replay cache is Redis-backed, keyed `(jkt, jti)`, with a TTL derived from the `iat` acceptance window (future + past tolerance plus a propagation margin), so a proof accepted once cannot be re-accepted while it is still inside the window. A replayed proof answers `401`.
- `iat` is accepted inside an asymmetric skew window: `iam.jwt.dpop_iat_future_tolerance` (default 10 s) into the future, `iam.jwt.dpop_iat_past_tolerance` (default 30 s) into the past.

Three presentations fail closed by design:

- `Authorization: Bearer <bound token>` — the downgrade path is closed by construction. The scheme itself must be `DPoP`.
- `Authorization: DPoP <unbound token>` — the reverse mismatch. An unbound token is a bearer token; the DPoP scheme names a credential type that does not exist for it. The strict gate answers `401` and challenges with `WWW-Authenticate: Bearer` (B-338).
- Bound token in the `auth_token` cookie (or a WebSocket subprotocol) — those transports cannot carry a proof, so a bound token never authenticates through them.

The API answers `401 {"error": "Authentication required"}` on every DPoP failure — missing proof, mismatched key, wrong `ath`/`htm`/`htu`, expired skew, replayed `jti` — with no detail about which check failed (anti-enumeration). The scheme-mismatch case above is the one failure that carries a `WWW-Authenticate: Bearer` challenge header — it tells the client which scheme to use, not which check failed. This also covers WebSocket: a bound token fails closed on the handshake (see [`websocket.md`](websocket.md) → App tokens on the handshake).

### `htu` is pinned to the configured origin

The server reconstructs `htu` exclusively from the configured public origin — `host` in `config.{env}.yml` (`FACET_HOST` in the release stack) — plus the request path, without query or fragment. It never consults `X-Forwarded-Proto` / `X-Forwarded-Host`: forwarded headers are attacker-controlled when a proxy is misconfigured, and trusting them would let an attacker pick an `htu` they hold a matching proof for.

The client rule: `htu` is the configured origin plus the request path. No query. No fragment. The server compares `htu` and ignores the query and fragment parts (RFC 9449 §4.3). The query string never enters the proof:

```http
GET /Api/crm/Company?per_page=1
→ proof htu: https://facet.example.tld/Api/crm/Company
```

Consequence for clients: **sign the configured origin, not the URL in the browser's address bar.** A proof whose `htu` differs in scheme, host, or port answers `400` at the token endpoint (and `401` at the API) with a message naming both URLs:

```
DPoP htu mismatch: expected https://facet.example.tld/OAuth/token, got http://facet.example.tld:8080/OAuth/token
```

Consequence for operators: a reverse proxy in front of Facet must either forward the public scheme and host unchanged, or `host` must be set to the exact public origin the clients see. A proxy that terminates TLS and forwards `http://backend:3000`-style internal origins breaks every DPoP client — set `host` (or `FACET_HOST`) to what the browser uses. The same configured origin is what discovery advertises as `issuer`.

### Claim contract

| Claim | Token endpoint | Refresh | API call | Violation |
| --- | --- | --- | --- | --- |
| `jti` | required, non-empty | required | required | grant → `400` (`invalid_claim`, or the replay code); API → `401` |
| `htm` | `POST` | `POST` | request method | mismatch → error |
| `htu` | token URL | token URL | request URL, no query or fragment | mismatch → error (names both URLs) |
| `iat` | required, inside the skew window | required | required | too old / too far future → error |
| `ath` | must be absent | must be absent | required, `base64url(SHA-256(access_token))` | wrong or unexpected `ath` → error |

Verification order: parse the JOSE header (reject private JWK members), verify the ES256 signature against the embedded public key, then the claims above, then the `(jkt, jti)` replay check. The proof key's thumbprint must equal the token's `cnf.jkt` (constant-time compare) before the replay check runs. On the token and refresh grants every failure is re-raised as that grant's own error type — `400` with the failure's error code (`invalid_dpop_proof`, `private_key_in_jwk`, `invalid_claim`, or `invalid_grant` on a replay); on the API surface every failure is the uniform `401`.

A working client lives at `e2e/fixtures/miniapp/index.html` — PKCE plus DPoP in vanilla JS, including the proof minting and the `DPoP` authorization scheme.

## Security properties

- **`redirect_uri` exact match, plus the loopback port wildcard.** A registered entry whose port is `*` (http loopback hosts only — `localhost`, any `*.localhost` subdomain, `127.0.0.1`, `::1`, per RFC 8252 §7.3) matches any port on the same host and scheme; a registered path pins the presented path. Every other entry matches exactly. A mismatch at `/OAuth/authorize` is rendered as an error response (`InvalidRequest`), never as a redirect — an unvalidated redirect target is the classic code-theft vector. The same rule applies at `/OAuth/token`: the `redirect_uri` presented at token must equal the one bound to the code at authorize time. Entries are shape-validated at write time by the `app.App` Lua hook (`util.valid_redirect_uri`): `https` on any host, `http` on a loopback host only, and a `*` nowhere but the port of an http loopback entry. The http carve-out is the native-app loopback convention (RFC 8252): a local redirect needs no TLS setup, and http on loopback never leaves the machine — it is not accepted on any other host.
- **`code_challenge_method` is `S256` only.** `plain` is rejected at `parse_params`.
- **Single-use codes.** `CodeStore.consume` runs a Lua `HGETALL`+`DEL` atomically: two concurrent redemptions cannot both see the record. A second redemption returns `nil` and the token endpoint responds `invalid_grant`.
- **PKCE verification is constant-time.** The server recomputes `Base64URL(SHA-256(code_verifier))` (RFC 7636 §4.2) from the presented verifier and compares in constant time against the stored challenge.
- **DPoP proofs are single-use and key-bound.** A bound token carries `cnf.jkt`; the API requires the `DPoP` scheme plus a fresh proof whose key thumbprint matches, whose `jti` was never seen, and whose `ath` matches the presented token. Bearer presentation of a bound token fails closed, and so does DPoP presentation of an unbound token (B-338). See [DPoP sender-constrained tokens](#dpop-sender-constrained-tokens-rfc-9449).
- **Refresh tokens are client-bound.** An app refresh token names the `client_id` that exchanged the code; the refresh grant must present the same value. A wrong-client attempt answers `401 invalid_grant` and leaves the session intact — the check runs before reuse detection, so probing a stolen refresh token cannot revoke the rightful client's session. See [Client binding on app refresh tokens](#client-binding-on-app-refresh-tokens).
- **Re-validation at token time.** `Token.call` consumes the code, then re-reads the `app.App` projection and re-runs `GrantResolver.role_usable?` + `resolve`. An app disabled or a grant narrowed between authorize (≤60s earlier) and the token exchange yields `invalid_grant`. The brief's atomic-consume rule means this path still invalidates the code.
- **Delegated app tokens are not connectivity-gated.** The role `connectivity` field gates the programmatic channels (`mcp`, `webhook`, `api`, `assistant` — see [`iam.md`](iam.md) → Roles); the delegated app branch is browser-session-mediated and is never gated by it — `validate_election` checks account-held + live only, and the channel check lives in the MCP branch alone (`issue_mcp_code`, `Refresh.call_mcp`). The MCP-branch check is the shared `IAM::Helpers.mcp_channel?` derivation — the same helper the consent screen (`build_mcp_consent`) and the `/Api/_mcp/endpoints` directory run, so the consent gate, the code issuance, and the endpoint listing can never disagree on which roles can open MCP.
- **Fail-closed enforcement.** `AuthHandler.build_app_auth_context` returns `nil` (HTTP 401) when the app is missing/non-active, the role is missing, the role is not usable, or the effective scope is empty.
- **CORS by exact origin match.** `OAuth::Cors` echoes the request `Origin` only when it appears in `app.App.allowed_origins` for at least one `active` app. No `*` is used — browsers ignore `Access-Control-Allow-Origin: *` when `Authorization` is in `Access-Control-Allow-Headers`. Each `allowed_origins` entry is shape-validated at create and update by the `app.App` Lua hook (`util.valid_origin`): a bare origin (`scheme://host[:port]`) with no path, userinfo, query, fragment, or wildcard, `https` on any host, `http` on a loopback host only (S6). The list still holds several origins — the CORS model is unchanged; only the per-entry shape is enforced.

## Consent screen always displayed

An account may hold multiple roles in Facet. An app login explicitly elects **one** role for the resulting session, so the consent screen is rendered every time the user reaches `/OAuth/authorize`. There is no "silent consent because you consented before" path and no consent store. The account's election is captured in the POST body and becomes the `role` claim of the issued app JWT.

## Origin cache invalidation

`OAuth::OriginCache` mirrors `Doctype::DefinitionStore` — `mark_stale` on every `app.App` mutation, lazy rebuild on the next read. `Event::Subscriber::AppCache` is the Pub/Sub listener that calls `mark_stale` — it never rebuilds, only signals staleness. Started in `main.cr` before `HTTP::Server.routes` so any `app.App` mutation published after startup is observed. A fanout lost during a Redis outage is bounded by `cache.staleness_ttl_s` — reads past the bound rebuild without a fanout (see `doc/backend/replication.md` → `Event::Subscriber::DoctypeCache` → staleness bound).

`Websocket::Route` also consults the cache for the `/Ws` upgrade origin allowlist — the same registered set `OAuth::Cors` mirrors for `/Api/*` — so a deployed app's origin can open a WebSocket without backend config or restart (`doc/backend/websocket.md`).

## Internal apps, not adversarial

The brief scopes the App System to internal, bespoke frontends (sometimes agent-generated) for an organization using Facet as its data + identity source. The security posture reflects that: `redirect_uris` and grant content are trusted; PKCE-protected clients only (no `client_secret` — a `confidential` app signs in through the same flow; its app-owned API key is the backend credential); CORS allows the app's registered origins on the token endpoint and the API directly. When confidential clients with real client secrets arrive in a later phase, `client_secret_hash` lives in a side table — secret material must never enter an append-only log that cannot be erased.
