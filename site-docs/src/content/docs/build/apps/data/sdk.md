---
type: how-to
title: The TypeScript SDK (`@facetapp/sdk`)
description: Query, write, and subscribe from TypeScript with the @facetapp/sdk SDK.
audience: [developer]
features: [APP-10]
sidebar:
  order: 1
verified_at: a77c6171
---

`@facetapp/sdk` is the TypeScript SDK for Facet apps. It wraps the HTTP API and the realtime
socket behind one typed client. It has zero runtime dependencies and runs in browsers and on
Node 20 or later, with the global `fetch`. It covers documents, queries, actions, children,
sidecars, aggregates, history, rollback, restore, backrefs, realtime, artifacts, and the
caller's permission manifest.

> **For agents:** Install with `pnpm add @facetapp/sdk`. Client: `createFacetClient({ baseUrl, auth })` with
> `staticKey(process.env.FACET_API_KEY!)` (backend app) or `oauthBrowser({ slug, redirectUri })` (browser app;
> then `await auth.signIn()` and `await auth.handleCallback(location.href)` on the callback route). Sequence:
> `facet.domain('crm').doctype('Company').list({ items: 50 })` → `page.next()` (null at the end) →
> `.doc(id).show()` → `.doc(id).update({ status: 'archived' })`; reach via `await facet.whoami()` and
> `await facet.can('read', 'crm.Company')`; errors are `ApiError` subclasses, local refusals throw `UsageError`.

## When to use this

Pick the SDK when:

- You build a TypeScript frontend or a Node service that talks to Facet.
- You want typed handles, paging, and typed errors instead of raw HTTP.
- You need realtime frames, file uploads, or the permission manifest in app code.

For raw HTTP control, or another language, use [Use the REST API](/build/apps/data/rest-api/).

## Before you start

- A running Facet instance and a registered app — see [Registering an app](/build/apps/connect/register/).
- A backend app needs an app-owned API key — see [service accounts and API keys](/build/apps/connect/backend-apps/).
- A browser app needs OAuth sign-in and an allowlisted origin — see
  [User login: OAuth 2.1 + PKCE](/build/apps/connect/user-login/) and [CORS and allowed origins](/build/apps/connect/cors/).
- The reach model: [Apps, grants and roles](/build/apps/connect/what-an-app-can-do/).

## Install and sign in

Install with `pnpm add @facetapp/sdk`. Two caller channels exist, and the SDK serves both.
Effective reach is always the intersection of the app grant and the role. The backend
re-resolves it on every request.

### Backend app: a static key

A backend app authenticates with an app-owned API key from an environment variable:

```ts
import { createFacetClient, staticKey } from '@facetapp/sdk';

const facet = createFacetClient({
	baseUrl: 'https://facet.example.com',
	auth: staticKey(process.env.FACET_API_KEY!)
});
```

The key belongs to the app's service account — see
[Service accounts for backend apps](/build/apps/connect/backend-apps/).

### Browser app: OAuth with PKCE

The account signs in through the consent screen. The consent screen elects one role for the app.

```ts
import { createFacetClient, oauthBrowser } from '@facetapp/sdk';

const auth = oauthBrowser({ slug: 'my-app', redirectUri: `${location.origin}/callback` });
const facet = createFacetClient({ baseUrl: 'https://facet.example.com', auth });

await auth.signIn(); // once, on the sign-in route; navigates to the consent screen
await auth.handleCallback(location.href); // on the redirect route
```

The refresh token is stored in `localStorage`; the access token stays in memory. Concurrent
`401` answers share one refresh call. A `429 slow_down` answer waits the server's wait period
and retries once. A failed refresh raises `AuthError`; the account signs in again. The code
blocks below reuse this `facet` client.

## Documents and queries

Every call starts from a handle tree: `facet.domain('crm')` returns a domain handle,
`.doctype('Company')` a collection handle, `.doc(id)` a document ref. No network call runs
until you call a method on a handle.

```ts
const companies = facet.domain('crm').doctype('Company');

const page = await companies.list({
	filters: { status__eq: 'active', created_at__gte: '2026-01-01' },
	sort: ['-updated_at'],
	items: 50
});
await page.next(); // null when meta.more is false
await companies.list({ aggregate: 'count', filters: { status__eq: 'active' } });

await companies.create({ name: 'Acme' });
await companies.create({
	$content: { name: 'Acme' },
	$children: { career_events: [{ event_type: 'hired' }] }
});

const doc = companies.doc(id);
await doc.show();
await doc.update({ status: 'archived' });
await doc.action('archive', { reason: 'done' });
await doc.history();
await doc.rollback(mutationId); // the state at this mutation
await doc.restore(); // undelete a tombstone
await doc.backrefs(); // live documents that reference this one
await doc.children('contacts').list();
await doc.sidecars('comments').list();
```

`doc.delete()` soft-deletes the document; `doc.restore()` brings a tombstone back.

The `list` parameters mirror the backend `ListRequest` grammar:

| Param | Purpose |
| --- | --- |
| `filters` | Raw `field__op` keys, for example `status__eq`. A bare key such as `search` passes through unchanged. |
| `sort` | Field names. A `-` prefix means descending. |
| `page`, `items` | Position and size. `items` clamps to 1..1000. |
| `aggregate`, `field` | `count` needs no `field`; `sum`, `avg`, `min`, and `max` take one. |
| `scope` | The name of one named scope on the doctype. |
| `select` | Field projection. Only these fields are returned. |
| `includeDeleted` | Set it to list tombstones — the trash listing. |

The SDK validates parameters before it sends anything. An unknown `__op` suffix raises
`UsageError`; so does a mix of `aggregate: 'count'` with `page` or `items`. No network call
runs. Paging values outside the bounds are clamped: `items` to 1..1000, `page` to 1 or more.

For faster reads, set `cache: true` on the client: `createFacetClient({ baseUrl, auth, cache: true })`.
Every `GET` then stores the strong ETag validator, and the next fetch of the same URL sends
`If-None-Match`. A `304` answer serves the cached envelope; a `200` replaces the entry. Mutating
verbs never touch the store. The cache is off by default; a custom store implements `get`, `set`,
and `delete` on a string key.

## What the token may do

`GET /Api/iam/me` answers for every credential the SDK holds. The manifest follows the
credential: a browser session reads the active role's manifest; an app token or an app-owned
key reads the resolved grant and role. A doctype that the grant does not name does not exist
in that manifest — there is no `*.*` fallback for app credentials.

```ts
await facet.whoami(); // cached after the first call
await facet.can('read', 'crm.Company'); // 'all' | 'scoped' | 'denied'
await facet.scopes('create', 'crm.Company'); // [] = unrestricted
await facet.refreshRights(); // re-fetch after a role switch or a grant change
```

The answers are advisory. The server re-resolves grant and role on every request and never
reads the manifest back. Use `can` to decide what the UI shows; never gate security with it.
Treat a denied call's `404` or `403` as the authority. See
[Gate your UI with the manifest](/build/apps/connect/permission-manifest/).

## Files and artifacts

Two ways exist to add a file. Attach it to a create or an update, or upload it standalone and
link the id. An upload alone gives no read access to others. An artifact becomes readable when
its id is stored in a `file` field or linked as `urn:facet:artifact:<id>` in a longtext.

```ts
// Attach: one multipart call; uploads and mutation share one transaction.
await companies.create({ name: 'Acme' }, { files: { logo: file } });
await doc.update({ name: 'Acme' }, { files: { 'items[0].file': file } });

const { id } = await facet.artifacts.upload(file);
await facet.artifacts.uploadAsUrn(file); // urn:facet:artifact:<id> for longtexts

const grant = await facet.artifacts.grant(id); // ephemeral; the server derives the TTL
await facet.artifacts.show(id);
await facet.artifacts.revoke(grant.grant_id);

await facet.artifacts.publish(id, { ownerId }); // permanent; needs the publish_artifact action
facet.artifacts.downloadUrl(id); // for <a href> and <img src>; fresh grant per request
facet.artifacts.downloadUrl(id, { appId }); // app-origin reads
await facet.artifacts.download(id); // follows the 302, returns the bytes
```

A grant is ephemeral; the server derives its lifetime from the media type. `downloadUrl` builds
the URL with no network call. See [Uploading and serving files](/build/apps/data/files/) for the model.

## Realtime

One lazy socket to `/Ws` multiplexes every subscription. `facet.realtime()` opens it on the
first subscribe. Frames are hints, never document state. The server sends no replay: re-fetch
what you subscribe to.

```ts
const rt = facet.realtime();
rt.onReconnect(() => companies.list({ items: 50 })); // no replay: re-fetch on reconnect

rt.subscribe('/crm/Company', (frame) => console.log(frame.event, frame.payload.id));
const off = await rt.subscribe(`/crm/Company/${id}`, (frame) => console.log(frame.event));

await rt.ensureConnected(); // optional: open the socket now
rt.close(); // stops the handle and drops every subscription
```

The `subscribe` promise settles on the first server message the handle traces to the path. An
in-band error frame — a rights denial or a subscription over the server cap — rejects it. A
matching data frame resolves it. On a quiet channel it stays pending; do not await it when
that matters; the handler receives frames regardless. Close codes are signals:

| Close code | Behaviour |
| --- | --- |
| `4401` | The handle refreshes the credential once and reconnects. A failed refresh raises `AuthError`. |
| `4403` | The origin is not allowlisted. The handle raises `AuthError` with no retry. |

Browsers offer `["facet-ws-v1", accessToken]` on the subprotocol list. Node 20 has no global
WebSocket; there, pass a header-capable constructor. The credential is then sent in the
`Authorization` header of the upgrade request. Static `fct_` keys are accepted there; the
subprotocol transport rejects them.

```ts
import { WebSocket } from 'ws'; // npm i -D @types/ws
import type { RealtimeWebSocketConstructor } from '@facetapp/sdk';

// Node 20: inject a header-capable constructor.
const rt = facet.realtime({ WebSocket: WebSocket as unknown as RealtimeWebSocketConstructor });
```

See [Realtime with WebSockets](/build/apps/data/realtime/) for the frame grammar and the channel paths.

## Errors

One base class exists, so app code branches on the class; `UsageError` is not an `ApiError`.

| Class | Raised on | Extra data |
| --- | --- | --- |
| `ApiError` | any failed exchange | `status`, `message`, `details`, `meta` |
| `AuthError` | missing credential, or a failed refresh or a refused socket credential | re-login hint message |
| `NotFoundError` | `404` — the backend denies with `404`, so it never discloses existence | — |
| `DeletedError` | `410` tombstone | `displayName`, `deletedAt` |
| `NetworkError` | `fetch` threw; the request never reached the server | — |
| `UsageError` | the SDK refused the call locally — bad params, closed handle. Not an `ApiError`; no exchange happened | — |

`details` carries the structured validation items: `field`, `message`, `code`, and `params`.

```ts
try {
	await companies.doc(id).show();
} catch (error) {
	if (error instanceof NotFoundError) console.log('absent, or hidden from this credential');
	else if (error instanceof DeletedError) console.log(error.displayName, error.deletedAt);
	else throw error;
}
```

## Troubleshooting

**Every call answers `401`.**

Facet re-checks the key and the app document on every request; a revoked key or a disabled app
answers `401`. Issue a new key — see [service accounts and API keys](/build/apps/connect/backend-apps/).

**A count call raises `UsageError`.**

`aggregate: 'count'` with `page` or `items` is refused before any network call. Drop the paging
parameters.

**The socket closes with `4403`.**

The origin is not on the allowlist. Register it — see
[CORS and allowed origins](/build/apps/connect/cors/).

**A call answers `NotFoundError` for a document that exists.**

Row scopes on the role or a missing grant hide the row; a `404` never discloses existence.
Check `facet.can('read', 'crm.Company')` — see
[Gate your UI with the manifest](/build/apps/connect/permission-manifest/).

## Related

- [Use the REST API](/build/apps/data/rest-api/) — the HTTP surface the SDK wraps.
- [User login: OAuth 2.1 + PKCE](/build/apps/connect/user-login/) — the browser sign-in flow in full.
- [DPoP token binding](/build/apps/connect/dpop/) — how app tokens bind to a key.
- [Realtime with WebSockets](/build/apps/data/realtime/) — the frame grammar behind `realtime()`.
- [Uploading and serving files](/build/apps/data/files/) — the artifact model, grants, and publishing.
- [Gate your UI with the manifest](/build/apps/connect/permission-manifest/) — the manifest behind `whoami`.
- Internals on GitHub: [packages/sdk/README.md](https://github.com/wearefacet/facet/blob/main/packages/sdk/README.md).
