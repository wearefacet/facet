---
type: how-to
title: "User login: OAuth 2.1 + PKCE"
description: Run the full authorization code + PKCE sign-in flow and handle its errors.
audience: [developer]
features: [APP-02, APP-05, FE-21]
sidebar:
  order: 1
verified_at: f1409cdc
---

An app signs an account in through the Facet consent screen. The flow is the OAuth 2.1
authorization code grant with PKCE (Proof Key for Code Exchange). The app sends the browser
to `/OAuth/authorize`, the account signs in and elects one role, and Facet redirects back with
a one-time code that the app exchanges for an access token and a refresh token.

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

A pure backend caller uses an app-owned API key instead — see [Backend apps](/build/apps/connect/backend-apps/).

## Before you start

- Register the app, publish it to `active`, and register the exact `redirect_uri` the app presents —
  see [Registering an app](/build/apps/connect/register/). The match is exact, plus a `*` port rule on http loopback hosts.
- Add the app origin to `allowed_origins`, so the browser may call the token endpoint — see
  [CORS and allowed origins](/build/apps/connect/cors/).
- The signing account must hold at least one role. The consent screen lists the roles the account holds.

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
the exchange to bind the token to a key — see [DPoP token binding](/build/apps/connect/dpop/). The `authorization_code`
grant counts 30 exchanges per `client_id` and IP per 5-minute window; refreshes are exempt.

### 5. Call the API with the access token

Send the token in `Authorization: Bearer <access_token>`, or with the `DPoP` scheme when the token
is bound. The token is an ES256 JWT with these claims:

| Claim | Value |
| --- | --- |
| `sub` | the account id |
| `sid` | a fresh app-session id |
| `role` | the elected role name |
| `app` | the app id |
| `typ` | `"app"` |

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
`refresh_token`.

## Example

This module runs the whole flow, bearer-only. Set the constants, serve the file from the app origin, and call
`startSignIn()` from a button:

```ts
// facet-signin.ts — a complete OAuth 2.1 + PKCE browser client, modelled on
// the reference client e2e/fixtures/miniapp/index.html.

const API_ORIGIN = 'https://facet.example.tld';
const CLIENT_ID = 'your-client-id';
const REDIRECT_URI = 'https://app.example.tld/oauth/callback'; // must equal a registered redirect_uri
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
60 seconds. A callback handler that runs twice sends a second exchange; only the first succeeds.

**Every API call answers `401` after the token worked for a while.** The access token passed its
`expires_in` lifetime. Refresh it, then retry the call. A refresh inside the 10-second floor after
the previous one answers `slow_down` — wait, then retry.

## Related

- [DPoP token binding](/build/apps/connect/dpop/) — bind the token to a key.
- [The TypeScript SDK (`@facetapp/sdk`)](/build/apps/data/sdk/) — `oauthBrowser` runs this flow for you, including the refresh floor.
- [Registering an app](/build/apps/connect/register/) — client id, redirect addresses, origins.
- [Apps, grants and roles](/build/apps/connect/what-an-app-can-do/) — the elected role and the grants bound every request.
- Internals on GitHub: [oauth.md](https://github.com/wearefacet/facet/blob/main/doc/backend/oauth.md).
