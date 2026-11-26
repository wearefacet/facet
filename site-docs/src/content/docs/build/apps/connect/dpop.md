---
type: how-to
title: DPoP token binding
description: Bind app tokens to a key with DPoP proofs on the token exchange and every API call.
audience: [developer]
features: [APP-03]
sidebar:
  order: 2
verified_at: a77c6171
---

DPoP (Demonstrating Proof-of-Possession, RFC 9449) binds an app token to one key pair. Stolen
token bytes alone cannot call the API: every call carries a fresh, signed proof. Binding is
optional at sign-in — an exchange without a `DPoP` header yields a plain bearer token. A bound
token fails closed at the API: every wrong presentation answers `401`.

> **For agents:** Make one ECDSA P-256 key pair before the redirect; keep the private JWK for the whole session.
> Mint a proof JWT — header `typ: "dpop+jwt"`, `alg: "ES256"`, `jwk` with the public members only; payload `jti`
> (fresh), `htm`, `htu`, `iat`, no `ath` — and send it in the `DPoP` header on `POST /OAuth/token`. The response
> then carries `token_type: "DPoP"` and the token embeds `cnf.jkt`. Every API call: `Authorization: DPoP <access_token>`
> plus a fresh proof with `ath = base64url(SHA-256(access_token))`. Sign `htu` as the configured origin plus path —
> never the address bar, never with a query. Refresh needs a fresh proof with the same key.

## When to use this

- **Token theft is your concern.** A stolen access token is useless without the private key.
- **Your app can hold a key.** It generates a key pair and keeps the private key for the whole
  session.
- **Not for cookies or WebSockets.** A bound token cannot ride a cookie or a WebSocket handshake —
  see [Realtime with WebSockets](/build/apps/data/realtime/).

  For an unbound bearer app, skip this page; the exchange sends no `DPoP` header.

## Before you start

- Run the sign-in flow first — see [User login: OAuth 2.1 + PKCE](/build/apps/connect/user-login/).
- Generate the key pair before the redirect, and keep the private material across the whole round
  trip. The reference client stores both JWKs in `sessionStorage`.
- A lost key gives a `401` with no hint. There is no recovery: generate a new key and start a new
  sign-in.

## Steps

### 1. Generate one key and keep it for the whole sign-in

Use one ECDSA P-256 key pair per sign-in. Keep the private JWK in the browser; Facet never sees
it. Every proof header carries only the public members `kty`, `crv`, `x`, `y` — a private member
such as `d` makes the proof invalid.

### 2. Mint an issuance proof on the token exchange

The proof is an ES256 JWT. The JOSE header carries `typ: "dpop+jwt"`, `alg: "ES256"`, and the
public `jwk`. The payload carries `jti` (a fresh random value), `htm: "POST"`, `htu` (the token
URL), and `iat` (unix seconds). No `ath` — the access token does not exist yet, and a proof that
carries one is rejected. Send the proof in the `DPoP` header on `POST /OAuth/token`. A verified
proof returns `token_type: "DPoP"`, and the access token embeds `cnf.jkt` — the thumbprint of the
proof key.

:::tip
The token endpoint verifies the proof before it consumes the code. A failed proof does not
consume the code — correct the proof and exchange the same code again.
:::

### 3. Refresh a bound session with the same key

Every refresh of a bound session needs a fresh proof with the same key: `jti`, `htm: "POST"`, the
token URL, `iat`, and no `ath`. A missing proof, a different key, or a replayed proof revokes the
session and answers `invalid_grant`.

### 4. Prove possession on every API call

Send the bound token with the `DPoP` scheme, plus a fresh proof on every request. The server
compares `htu` and ignores the query and fragment parts, so the query string never enters the
proof:

```http
GET /Api/crm/Company?per_page=1
→ proof htu: https://facet.example.tld/Api/crm/Company
```

The proof contract, per claim:

| Claim | Token endpoint | Refresh | API call | Violation |
| --- | --- | --- | --- | --- |
| `jti` | required, non-empty | required | required, new per request | grant: `400`; API: `401` |
| `htm` | `POST` | `POST` | the request method | mismatch: error |
| `htu` | the token URL | the token URL | request path, no query, no fragment | mismatch: error, names both URLs |
| `iat` | inside the skew window | inside the skew window | inside the skew window | outside the window: error |
| `ath` | must be absent | must be absent | required: `base64url(SHA-256(access_token))` | wrong or unexpected: error |

`jti` values are single-use; the server caches accepted values, so a replayed proof answers `401`.
The `iat` window accepts 10 seconds into the future and 30 seconds into the past (defaults). At
the token and refresh grants, a proof failure answers `400` — `invalid_dpop_proof` for structure
or signature faults, `invalid_claim` for payload faults, `invalid_grant` on a replay. At the API,
every failure is the uniform `401`.

### 5. Sign the configured origin, not the address bar

The server rebuilds `htu` from the configured public origin only. It never reads `X-Forwarded-*`
headers. A proof whose `htu` differs in scheme, host, or port answers `400` at the token endpoint
and `401` at the API, with a message that names both URLs:
`DPoP htu mismatch: expected https://facet.example.tld/OAuth/token, got http://facet.example.tld:8080/OAuth/token`.

:::caution
A TLS-terminating proxy must forward the public origin, or the operator must set `host` (or
`FACET_HOST` in the release stack) to the origin the browser uses. A proxy that forwards internal
origins breaks every DPoP client.
:::

### 6. Know what fails closed

Three presentations fail by design, and every other DPoP failure answers the same body:

| Presentation | Answer |
| --- | --- |
| `Bearer` scheme with a bound token | `401` — the downgrade path is closed |
| `DPoP` scheme with an unbound token | `401` with `WWW-Authenticate: Bearer` — the one failure that names the fix |
| A bound token in the `auth_token` cookie or a WebSocket subprotocol | `401` — those transports cannot carry a proof |
| Any other DPoP failure — missing proof, wrong key, wrong `ath`/`htm`/`htu`, expired skew, replayed `jti` | `401 {"error": "Authentication required"}` — no detail about the failed check |

## Example

This module holds the key, mints proofs, exchanges the code, and makes one bound API call.
Generate and save the key before `location.assign(...)` in your sign-in:

```ts
// facet-dpop.ts — DPoP key, proof minting, and bound API calls, modelled on
// the reference client e2e/fixtures/miniapp/index.html.

const API_ORIGIN = 'https://facet.example.tld';
const TOKEN_URL = `${API_ORIGIN}/OAuth/token`;
const DPOP_STORAGE = 'facet.dpop';

interface DpopKey {
  pub: { kty: string; crv: string; x: string; y: string };
  jkt: string;
  privateJwk: JsonWebKey;
}

function b64url(bytes: Uint8Array): string {
  let binary = '';
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

async function sha256B64url(text: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return b64url(new Uint8Array(digest));
}

export async function generateDpopKey(): Promise<DpopKey> {
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, [
    'sign',
    'verify'
  ]);
  const jwk = await crypto.subtle.exportKey('jwk', pair.publicKey);
  const pub = { kty: jwk.kty as string, crv: jwk.crv as string, x: jwk.x as string, y: jwk.y as string };
  // RFC 7638 thumbprint: canonical JSON, sorted members, SHA-256, base64url.
  const jkt = await sha256B64url(JSON.stringify({ crv: pub.crv, kty: pub.kty, x: pub.x, y: pub.y }));
  return { pub, jkt, privateJwk: await crypto.subtle.exportKey('jwk', pair.privateKey) };
}

export function saveDpopKey(key: DpopKey): void {
  sessionStorage.setItem(DPOP_STORAGE, JSON.stringify(key));
}

function loadDpopKey(): DpopKey | null {
  const raw = sessionStorage.getItem(DPOP_STORAGE);
  return raw === null ? null : (JSON.parse(raw) as DpopKey);
}

export async function signDpopProof(key: DpopKey, htm: string, htu: string, ath?: string): Promise<string> {
  const header = { alg: 'ES256', typ: 'dpop+jwt', jwk: key.pub };
  const payload: Record<string, unknown> = {
    jti: crypto.randomUUID(),
    htm,
    htu,
    iat: Math.floor(Date.now() / 1000)
  };
  if (ath !== undefined) payload.ath = ath;

  const encoder = new TextEncoder();
  const signingInput =
    `${b64url(encoder.encode(JSON.stringify(header)))}.` +
    `${b64url(encoder.encode(JSON.stringify(payload)))}`;
  const signingKey = await crypto.subtle.importKey(
    'jwk', key.privateJwk, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']
  );
  const signature = await crypto.subtle.sign(
    { name: 'ECDSA', hash: 'SHA-256' },
    signingKey,
    encoder.encode(signingInput)
  );
  return `${signingInput}.${b64url(new Uint8Array(signature))}`;
}

export async function exchangeBoundToken(
  code: string, verifier: string, clientId: string, redirectUri: string
): Promise<Response> {
  const key = loadDpopKey();
  if (!key) throw new Error('No DPoP key in this browser session.');
  const proof = await signDpopProof(key, 'POST', TOKEN_URL);
  const body = new URLSearchParams({
    grant_type: 'authorization_code', code, client_id: clientId, redirect_uri: redirectUri,
    code_verifier: verifier
  });
  return fetch(TOKEN_URL, {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded', DPoP: proof },
    body
  });
}

export async function readCompanies(accessToken: string): Promise<Response> {
  const key = loadDpopKey();
  if (!key) throw new Error('No DPoP key in this browser session.');
  const htu = `${API_ORIGIN}/Api/crm/Company`;
  const ath = await sha256B64url(accessToken);
  const proof = await signDpopProof(key, 'GET', htu, ath);
  return fetch(htu, { headers: { Authorization: `DPoP ${accessToken}`, DPoP: proof } });
}
```

The exchange answers `token_type: "DPoP"` when the server accepted the proof. The model for this module is the
working reference client
[e2e/fixtures/miniapp/index.html](https://github.com/wearefacet/facet/blob/main/e2e/fixtures/miniapp/index.html)
— PKCE plus DPoP in vanilla JavaScript, including the proof minting and the `DPoP` authorization scheme.

## Troubleshooting

**`400` with `DPoP htu mismatch`.** The proof signed the wrong origin. The message names both
URLs. Sign the configured origin plus path, with no query and no fragment.

**`401` right after the redirect, with no hint.** The key was lost — `sessionStorage` was cleared,
or the callback ran in another tab. Generate a new key and restart the sign-in.

**`401` on a call that worked before.** A replayed `jti` — the same proof object was reused. Mint
a fresh proof per request; never reuse a proof string.

**`401` with a valid bound token.** A check failed: missing `ath`, wrong `htm` or `htu`, expired skew, or the
`Bearer` scheme. The body does not say which check — recheck the proof claims against the table above.

**`401` with a `WWW-Authenticate: Bearer` challenge.** The token is unbound. Drop the `DPoP`
scheme, or sign in again with a proof on the exchange.

## Related

- [User login: OAuth 2.1 + PKCE](/build/apps/connect/user-login/) — the sign-in flow this page binds.
- [The TypeScript SDK (`@facetapp/sdk`)](/build/apps/data/sdk/) — the SDK client and its `oauthBrowser` sign-in.
- [Realtime with WebSockets](/build/apps/data/realtime/) — a bound token cannot ride the handshake.
- Internals on GitHub: [oauth.md](https://github.com/wearefacet/facet/blob/main/doc/backend/oauth.md).
