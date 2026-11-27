---
type: how-to
title: Sign users in
description: Run the OAuth 2.1 authorization code flow with PKCE, from the consent screen to the refresh grant.
audience: [developer]
features: [APP-02, APP-05, FE-21]
sidebar:
  order: 1
verified_at: eee55a2
---

Your browser app signs Brightwater's people in through Facet, and the app

never sees a password. The flow is OAuth 2.1: the authorization code grant

with PKCE (Proof Key for Code Exchange). The app sends the browser to

`/OAuth/authorize`. The account signs in and elects one role. Facet

redirects back with a one-time code, and the app exchanges it for an access

token and a refresh token.

> **For agents:** Public client, no secret. Build `code_verifier` (random base64url, 43–128 characters) and
> `code_challenge = base64url(SHA-256(verifier))`; keep `verifier` and `state` in `sessionStorage`. Navigate to
> `GET /OAuth/authorize` with `response_type=code`, `client_id`, `redirect_uri`, `code_challenge`, `code_challenge_method=S256`, `state`.
> On the callback, check `state`, then POST `/OAuth/token`, form-encoded: `grant_type=authorization_code`, `code`,
> `client_id`, `redirect_uri`, `code_verifier`. Response: `access_token`, `token_type`, `expires_in`, `refresh_token`.
> Refresh: `grant_type=refresh_token` plus the same `client_id`; keep 10 seconds between refreshes, or get `429 slow_down`.

## When to use this

Use this page when:

- You build a browser or native app that signs an account in through the consent screen.
- You need the redirect round trip: authorize, consent, callback, token exchange.

A pure backend caller uses an app-owned API key instead — see
[Backend apps and service accounts](/build/apps/connect/backend-apps/).

## Before you start

- Register the app, publish it to `active`, and register the exact `redirect_uri` the app presents —
  see [Register an app](/build/apps/connect/register/). The match is exact, plus a `*` port rule on http loopback hosts.
- Add the app origin to `allowed_origins`, so the browser may call the token endpoint — see
  [Allowed origins and CORS](/build/apps/connect/cors/).
- The signing account must hold at least one role. The consent screen lists the roles the account holds that
  cover the app's required grants.

## Steps

Here is the sign-in round trip:

<!-- d2
direction: down
pkce: "App builds the PKCE pair" {class: external}
authorize: "Browser opens /OAuth/authorize"
session: "Browser session present?" {class: decision}
login: "302 to /Login"
signin: "Account signs in"
consent: "302 to /OAuthConsent"
elect: "Consent posts the election"
redirect: "302 to redirect_uri with code and state"
token: "App POSTs /OAuth/token with the verifier"
calls: "App stores tokens and calls the API" {class: ok}

pkce -> authorize
authorize -> session
session -> login: no
login -> signin
signin -> authorize
session -> consent: yes
consent -> elect: account elects one role
elect -> redirect
redirect -> token
token -> calls
-->
<div class="d2-diagram">
<img class="d2-diagram__img d2-diagram__light" src="/diagrams/500212d3-light.svg" alt="App builds the PKCE pair" loading="lazy" />
<img class="d2-diagram__img d2-diagram__dark" src="/diagrams/500212d3-dark.svg" alt="App builds the PKCE pair" loading="lazy" />
</div>

### 1. Generate the PKCE pair

Make a `code_verifier`: a random base64url string between 43 and 128 characters (RFC 7636); the reference
client uses 64. Compute `code_challenge = base64url(SHA-256(code_verifier))`. The `S256` method is the only
accepted method; `plain` is refused. Save `code_verifier` and `state` in `sessionStorage` — the callback must
find them again.

From a terminal, the pair looks like this:

```sh
openssl rand -base64 48 | tr '+/' '-_' | tr -d '='
# YF-tTGf8ZKzGRypHYm6fyrF_W45UApWMR8Zas5EuoW8n1IBgIFyrzUndX1vQdu9F  <- code_verifier

printf '%s' 'YF-tTGf8ZKzGRypHYm6fyrF_W45UApWMR8Zas5EuoW8n1IBgIFyrzUndX1vQdu9F' \
  | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '='
# JNVgr1Czh8QJ1zYgaq6fQFQT5bbfH90Snk4IEaRPQAc  <- code_challenge
```

### 2. Send the browser to the authorize endpoint

Navigate the browser to `GET /OAuth/authorize` with these parameters:

| Parameter | Value |
| --- | --- |
| `response_type` | `code` |
| `client_id` | the app's client id |
| `redirect_uri` | the registered address, exactly as registered |
| `code_challenge` | `base64url(SHA-256(code_verifier))` |
| `code_challenge_method` | `S256` |
| `state` | a random value the app checks on the callback |

Without a browser session, the endpoint answers `302` to `/Login?redirectTo=…` with the authorize
URL embedded; the login page returns the browser to the authorize URL after sign-in. With a
session, the endpoint redirects the browser to the `/OAuthConsent` route. The consent screen always
shows — the account elects exactly one role for the app; there is no silent consent.

The screen is built from a JSON payload the page fetches. For the Brightwater
check-out app, Ravi's payload reads:

```json
{
  "app": {
    "id": "06H1FQF7NGDJJKSNHXPYT6627M",
    "client_id": "06H1FQF7NG357EQ0P348Z2BEV5",
    "slug": "brw-checkout",
    "display_name": "Brightwater Check-out",
    "description": "The warehouse check-out board: today's bookings, with the items each booking needs. Marks items out and back in.",
    "redirect_uris": ["http://localhost:5173/auth/callback"],
    "allowed_origins": ["http://localhost:5173"],
    "status": "active"
  },
  "roles": [
    {
      "role_id": "iam.Roles.admin",
      "display_name": "Full administrative access to all resources.",
      "effective_scope": [
        { "target": "rentals.Booking", "actions": ["read"] },
        { "target": "rentals.BookingLine", "actions": ["read"] },
        { "target": "equipment.Item", "actions": ["read", "create", "update"] }
      ]
    }
  ],
  "state": "winter-fair-43",
  "requested_scope": null
}
```

Each entry under `roles` is one role the account may elect, with
`effective_scope` showing what the app would keep for that role — the
grant ∩ the role, computed live. A role that covers none of the app's
required grant actions does not appear at all.

### 3. Handle the callback

Facet redirects to `redirect_uri` with `code` and `state` in the query. Compare `state` with the value the app
saved before the redirect; a mismatch means the redirect did not come from this sign-in.

### 4. Exchange the code at the token endpoint

POST the code to `POST /OAuth/token`, with an `application/x-www-form-urlencoded` body:

```http
POST /OAuth/token HTTP/1.1
Content-Type: application/x-www-form-urlencoded

grant_type=authorization_code&code=AUTH_CODE&client_id=CLIENT_ID&redirect_uri=REDIRECT_URI&code_verifier=VERIFIER
```

The response carries `access_token` (the app JWT, signed with ES256), `token_type` (`"DPoP"` when the
exchange carried a DPoP proof, `"Bearer"` otherwise), `expires_in` (access-token lifetime in seconds —
`iam.jwt.access_token_ttl`, default `900`), and `refresh_token`. The token is not renewed: when
`expires_in` elapses, call the refresh grant in step 6 before the next API call. There is no `scope`
member — Facet advertises no scope vocabulary. Add a `DPoP` header to
the exchange to bind the token to a key — see
[Bind tokens to your app (DPoP)](/build/apps/connect/dpop/). The `authorization_code`
grant counts 30 exchanges per `client_id` and IP per 5-minute window; refreshes are exempt.

The exchange for the walkthrough sign-in answered:

```json
{
  "access_token": "eyJ0eXAiOiJKV1QiLCJhbGciOiJFUzI1NiIsImtpZCI6ImZhY2V0LTEifQ.eyJzdWIiOiIwNkgxRk0wOThXQjJCN1g1QkE0OTQ2Nks0TiIsInNpZCI6IjQyZTliY2I2MGVmMGI3ZmQ3OTY1M2UxNDFkNTMyMjI2NmY2ODE3ZjY2MWRjZjUwNjQzNmE1YWQ2ZDVjNGM4M2EiLCJyb2xlIjoiaWFtLlJvbGVzLmFkbWluIiwianRpIjoiMDZIMUc0RlY5Q05RSDNLOThFTURTTUFBWjkiLCJ0eXAiOiJhcHAiLCJpYXQiOjE3OTU3MDAxNjEsImV4cCI6MTc5NTcwMTA2MSwiYXBwIjoiMDZIMUZRRjdOR0RKSktTTkhYUFlUNjYyN00ifQ.AqrsiB6iDvRCasWYNdlauDPTOuXSBERFmV-baW1aAlgd-HUxXI7s81PiDBFEBcognYPtyDM5tGieS5-OvXafAw",
  "token_type": "Bearer",
  "expires_in": 900,
  "refresh_token": "42e9bcb60ef0b7fd79653e141d5322266f6817f661dcf506436a5ad6d5c4c83a.a91913d305aac321675056fd92fb5cf4be2e3827209e79cdf140f548f4b1538d"
}
```

### 5. Call the API with the access token

Send the token in `Authorization: Bearer <access_token>`, or with the `DPoP` scheme when the token
is bound. The token is an ES256 JWT with these claims — the payload of the
token above, decoded:

| Claim | Value |
| --- | --- |
| `sub` | the account id — `06H1FM098WB2B7X5BA49466K4N` |
| `sid` | a fresh app-session id — `42e9bcb60ef0b7fd79653e141d5322266f6817f661dcf506436a5ad6d5c4c83a` |
| `role` | the elected role — `iam.Roles.admin` |
| `app` | the app id — `06H1FQF7NGDJJKSNHXPYT6627M` |
| `typ` | `"app"` |
| `jti`, `iat`, `exp` | the token id, issued-at, and expiry (900 seconds after `iat`) |

### 6. Refresh the session

POST `grant_type=refresh_token` with the `refresh_token` and the same `client_id`:

```http
POST /OAuth/token HTTP/1.1
Content-Type: application/x-www-form-urlencoded

grant_type=refresh_token&refresh_token=REFRESH_TOKEN&client_id=CLIENT_ID
```

The refresh token is client-bound: a missing or different `client_id` answers `401 invalid_grant` and leaves
the session intact. Every refresh re-reads live state — account, role, app status, and grant; a failed check
revokes the session. A refresh sooner than 10 seconds after the last one answers
`429 {"error": "slow_down"}` — wait, then retry. The response carries a fresh `access_token` and a rotated
`refresh_token`:

```json
{
  "access_token": "eyJ0eXAiOiJKV1QiLCJhbGciOiJFUzI1NiIsImtpZCI6ImZhY2V0LTEifQ.eyJzdWIiOiIwNkgxRk0wOThXQjJCN1g1QkE0OTQ2Nks0TiIsInNpZCI6IjQyZTliY2I2MGVmMGI3ZmQ3OTY1M2UxNDFkNTMyMjI2NmY2ODE3ZjY2MWRjZjUwNjQzNmE1YWQ2ZDVjNGM4M2EiLCJyb2xlIjoiaWFtLlJvbGVzLmFkbWluIiwianRpIjoiMDZIMUc1SDVLODdETjNRRDZWN0hWVlpEWFkiLCJ0eXAiOiJhcHAiLCJpYXQiOjE3OTU3MDA0MzQsImV4cCI6MTc5NTcwMTMzNCwiYXBwIjoiMDZIMUZRRjdOR0RKSktTTkhYUFlUNjYyN00ifQ.OXS2AmjdTMDFOl_IPfa77j-lbGOPZ7formHoF4SxIHzUuItfLCbCh64-Cz_ffA4EUkAYiVHIcDOxB9mFhSinuA",
  "token_type": "Bearer",
  "expires_in": 900,
  "refresh_token": "42e9bcb60ef0b7fd79653e141d5322266f6817f661dcf506436a5ad6d5c4c83a.8a10cdea40171e71c96fc7eaaab8ed1aabd11a84cf0a2b9c1d3783bf26a44790"
}
```

Same `sid`, fresh `jti` — the session continues, the credential turned over.

## Example

This module runs the whole flow, bearer-only. Set the constants, serve the file from the app origin, and call
`startSignIn()` from a button:

```ts
// facet-signin.ts — a complete OAuth 2.1 + PKCE browser client, modelled on
// the reference client e2e/fixtures/miniapp/index.html.

const API_ORIGIN = 'https://facet.localhost:3443';
const CLIENT_ID = '06H1FQF7NG357EQ0P348Z2BEV5';
const REDIRECT_URI = 'http://localhost:5173/auth/callback'; // must equal a registered redirect_uri
const AUTHORIZE_PATH = '/OAuth/authorize';
const TOKEN_PATH = '/OAuth/token';
const STORAGE_KEY = 'facet.signin';

interface TokenResponse {
  access_token: string;
  token_type: string;
  expires_in: number;
  refresh_token: string;
}

function b64url(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function randomB64url(characters: number): string {
  const bytes = new Uint8Array(characters);
  crypto.getRandomValues(bytes);
  return b64url(bytes).slice(0, characters);
}

async function sha256B64url(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return b64url(new Uint8Array(digest));
}

export async function startSignIn(): Promise<void> {
  const verifier = randomB64url(64);
  const state = randomB64url(16);
  const challenge = await sha256B64url(verifier);
  sessionStorage.setItem(STORAGE_KEY, JSON.stringify({ verifier, state }));

  const url = new URL(AUTHORIZE_PATH, API_ORIGIN);
  url.searchParams.set('response_type', 'code');
  url.searchParams.set('client_id', CLIENT_ID);
  url.searchParams.set('redirect_uri', REDIRECT_URI);
  url.searchParams.set('code_challenge', challenge);
  url.searchParams.set('code_challenge_method', 'S256');
  url.searchParams.set('state', state);
  location.assign(url.toString());
}

export async function handleCallback(redirectUrl: string): Promise<TokenResponse> {
  const query = new URLSearchParams(new URL(redirectUrl).search);
  const raw = sessionStorage.getItem(STORAGE_KEY);
  if (query.get('code') === null || raw === null) {
    throw new Error('No sign-in attempt found in this browser session.');
  }
  const attempt = JSON.parse(raw) as { verifier: string; state: string };
  if (attempt.state !== query.get('state')) {
    throw new Error('State mismatch — the redirect did not come from this sign-in.');
  }

  const body = new URLSearchParams({
    grant_type: 'authorization_code', code: query.get('code')!, client_id: CLIENT_ID,
    redirect_uri: REDIRECT_URI, code_verifier: attempt.verifier
  });
  const response = await fetch(`${API_ORIGIN}${TOKEN_PATH}`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
    body
  });
  const payload = await response.json();
  if (!response.ok) {
    const detail = `${payload.error ?? ''} ${payload.error_description ?? ''}`.trim();
    throw new Error(`Token exchange failed (HTTP ${response.status}): ${detail}`);
  }
  sessionStorage.removeItem(STORAGE_KEY);
  return payload as TokenResponse;
}
```

On the callback page, run `handleCallback(location.href)` and store the returned tokens. The model
for this module is the working reference client
[e2e/fixtures/miniapp/index.html](https://github.com/wearefacet/facet/blob/main/e2e/fixtures/miniapp/index.html).

## Troubleshooting

Every error is a JSON body: `{"error": "<code>", "error_description": "<detail>"}`.

| Error | Where | Cause |
| --- | --- | --- |
| `invalid_request` | authorize, token | a parameter is missing or malformed |
| `access_denied` | authorize | the account denied consent, or the election POST carried a malformed `role` value |
| `invalid_grant` | token | wrong `code_verifier`; the code expired (60-second TTL); the code was already consumed; the app was disabled or a grant narrowed between authorize and exchange; wrong or missing `client_id` on refresh; refresh-token reuse |
| `slow_down` | token, refresh | `429` — a refresh sooner than 10 seconds after the last one |
| `unknown_client` | `GET /OAuth/client-info` | `404` — unknown slug, or the app is not active |

:::caution
The consent confirm POST names the elected role in a `role` field, with the qualified value
`iam.Roles.<name>`. The consent payload lists the roles under `role_id`. A hand-rolled consent
client that posts `role_id` gets `access_denied`.
:::

**A redirect_uri mismatch renders an error page, never a redirect.** Facet refuses to redirect to an
unvalidated target. Check the registered address; the match is exact outside the http loopback port rule.

**State mismatch after the redirect.** `sessionStorage` lost the saved pair — a new tab or a
server-side render does not share it. Keep the attempt in the tab that started the sign-in.

**`invalid_grant` on a code you believe is correct.** The code is single-use and expires after
60 seconds. A callback handler that runs twice sends a second exchange; only the first succeeds:

```json
{"error": "invalid_grant", "error_description": "Authorization code is invalid, expired, or already used"}
```

Start the sign-in again.

**The consent screen lists no roles for this account.** The account's roles
do not cover the app's required grant actions — check which actions the
grants mark `required: true`, and which lines the roles carry. An
administrator can widen a role or narrow the app's grants — see
[Control what apps can reach](/admin/apps-access/app-grants/).

**Every API call answers `401` after the token worked for a while.** The access token passed its
`expires_in` lifetime. Refresh it, then retry the call. A refresh inside the 10-second floor after
the previous one answers `slow_down` — wait, then retry.

## Related

- [Bind tokens to your app (DPoP)](/build/apps/connect/dpop/) — bind the token to a key.
- [The TypeScript SDK](/build/apps/data/sdk/) — `oauthBrowser` runs this flow for you, including the refresh floor.
- [Register an app](/build/apps/connect/register/) — client id, redirect addresses, origins.
- [Apps, grants and roles](/build/apps/connect/what-an-app-can-do/) — the elected role and the grants bound every request.
- Internals on GitHub: [oauth.md](https://github.com/wearefacet/facet/blob/main/doc/backend/oauth.md).
