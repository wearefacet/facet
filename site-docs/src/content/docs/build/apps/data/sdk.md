---
title: The TypeScript SDK
description: Query, write, and subscribe from TypeScript with the typed @facetapp/sdk client.
type: how-to
audience: [developer]
features: [APP-10]
verified_at: eee55a2
sidebar:
  order: 1
---

`@facetapp/sdk` is the TypeScript SDK for Facet apps. It wraps the HTTP API
and the realtime socket behind one typed client. It has zero runtime
dependencies, runs in browsers and on Node 20 or later, and covers documents,
queries, actions, children, sidecars, aggregates, history, rollback, files,
realtime, and the caller's permission manifest. Every example on this page
type-checks against the current package.

> **For agents:** Install with `pnpm add @facetapp/sdk`. Client: `createFacetClient({ baseUrl, auth })`
> with `staticKey(process.env.FACET_API_KEY!)` (backend app) or `oauthBrowser({ slug, redirectUri })`
> (browser app; `await auth.signIn()` then `await auth.handleCallback(location.href)` on the callback route).
> Sequence: `facet.domain('clients').doctype('Company').list({ items: 20 })` → `page.next()` (null at the end) →
> `.doc(id).show()` → `.doc(id).update({ city: 'Annecy' })`; rights via `await facet.whoami()` and
> `await facet.can('update', 'clients.Company')`; errors are `ApiError` subclasses; local refusals throw
> `UsageError` before any network call.

## When to use this

Pick the SDK when:

- You build a TypeScript frontend or a Node service that talks to Facet.
- You want typed handles, paging, and typed errors instead of raw HTTP.
- You need realtime frames, file uploads, or the permission manifest in app
  code.

For raw HTTP control, or another language, use
[Use the REST API](/build/apps/data/rest-api/).

## Before you start

- Node 20 or newer, or any modern browser.
- A backend app needs an app-owned API key — see
  [Service accounts for backend apps](/build/apps/connect/backend-apps/).
- A browser app needs OAuth sign-in and an allowlisted origin — see
  [User login: OAuth 2.1 + PKCE](/build/apps/connect/user-login/).
- The reach model: [Apps, grants and roles](/build/apps/connect/what-an-app-can-do/).

## Install and sign in

```sh
pnpm add @facetapp/sdk
```

Two caller channels exist, and the SDK serves both. Effective reach is
always the intersection of the app grant and the role; the backend
re-resolves it on every request.

### Backend app: a static key

A backend app authenticates with an app-owned API key from an environment
variable:

```ts
import { createFacetClient, staticKey } from '@facetapp/sdk';

const facet = createFacetClient({
	baseUrl: 'https://facet.localhost:3443',
	auth: staticKey(process.env.FACET_API_KEY!)
});
```

### Browser app: OAuth with PKCE

The account signs in through the consent screen. The consent screen elects
one role for the app:

```ts
import { createFacetClient, oauthBrowser } from '@facetapp/sdk';

const auth = oauthBrowser({
	slug: 'brightwater-portal',
	redirectUri: 'https://portal.brightwater.example/callback',
	baseUrl: 'https://facet.localhost:3443'
});

const facet = createFacetClient({ baseUrl: 'https://facet.localhost:3443', auth });

if (location.search.includes('code=')) {
	await auth.handleCallback(location.href);
} else {
	await auth.signIn();
}
```

The refresh token is stored in `localStorage`; the access token stays in
memory. Concurrent `401` answers share one refresh call. A failed refresh
raises `AuthError`; the account signs in again. The examples below reuse this
`facet` client.

## Documents and queries

Every call starts from a handle tree: `facet.domain('clients')` returns a
domain handle, `.doctype('Company')` a collection handle, `.doc(id)` a
document ref. No network call runs until you call a method on a handle.

```ts
import { createFacetClient, staticKey } from '@facetapp/sdk';

const facet = createFacetClient({
	baseUrl: 'https://facet.localhost:3443',
	auth: staticKey('fct_...')
});

const companies = facet.domain('clients').doctype('Company');

const page = await companies.list({
	filters: { city__eq: 'Lyon' },
	sort: ['-created_at'],
	items: 20
});

for (const row of page.data) {
	console.log(row.meta.display_name, row.data.city);
}

const nextPage = await page.next(); // null when meta.more is false
```

A full write round-trip, including the two error cases worth handling:

```ts
import { createFacetClient, staticKey, ApiError, DeletedError } from '@facetapp/sdk';

const facet = createFacetClient({
	baseUrl: 'https://facet.localhost:3443',
	auth: staticKey('fct_...')
});
const companies = facet.domain('clients').doctype('Company');

const created = await companies.create({ name: 'Atelier Vermeil', city: 'Lyon' });
console.log(created.meta.id, created.meta.display_name);

const ref = companies.doc(created.meta.id);
await ref.update({ city: 'Annecy' });

try {
	await ref.show();
} catch (e) {
	if (e instanceof DeletedError) {
		console.log('deleted at', e.deletedAt, 'label', e.displayName);
	} else if (e instanceof ApiError && e.status === 404) {
		console.log('gone');
	}
}

await ref.delete();
```

Document refs carry the rest of the surface:

```ts
await doc.action('confirm', { note: 'deposit paid' }); // a named action
await doc.history();        // the mutation log, newest first
await doc.rollback(mutationId); // the state at this mutation
await doc.restore();        // undelete a tombstone
await doc.backrefs();       // live documents that reference this one
await doc.children('contacts').list();  // a child collection
await doc.sidecars('comments').list();  // a sidecar segment
```

`doc.delete()` soft-deletes the document; `doc.restore()` brings a tombstone
back.

The `list` parameters mirror the backend list grammar:

| Param | Purpose |
| --- | --- |
| `filters` | Raw `field__op` keys, for example `status__eq`. A bare key such as `search` passes through unchanged. |
| `sort` | Field names. A `-` prefix means descending. |
| `page`, `items` | Position and size. `items` clamps to 1..1000. |
| `aggregate`, `field` | `count` needs no `field`; `sum`, `avg`, `min`, and `max` take one. |
| `scope` | The name of one named scope on the doctype. |
| `select` | Field projection. Only these fields are returned. |
| `includeDeleted` | Set it to list tombstones — the trash listing. |

The SDK validates parameters before it sends anything, so a typo never
reaches the server:

```ts
import { createFacetClient, staticKey, UsageError } from '@facetapp/sdk';

const facet = createFacetClient({
	baseUrl: 'https://facet.localhost:3443',
	auth: staticKey('fct_...')
});
const companies = facet.domain('clients').doctype('Company');

try {
	await companies.list({ aggregate: 'count', page: 2 });
} catch (e) {
	if (e instanceof UsageError) console.log('refused before any network call:', e.message);
}

try {
	await companies.list({ filters: { name__regex: 'x' } });
} catch (e) {
	if (e instanceof UsageError) console.log('unknown operator:', e.message);
}
```

The messages name the fix:

```text
refused before any network call: aggregate: 'count' ignores page and items. Drop them, so the call does not ask for a page the server will not serve.
unknown operator: Unknown filter operator 'regex' in 'name__regex'. Use one of: eq, ne, gt, gte, lt, lte, match, starts_with, between, in, currency, contains, overlaps, within.
```

Scopes, projection, and children ride the same call:

```ts
import { createFacetClient, staticKey } from '@facetapp/sdk';

const facet = createFacetClient({
	baseUrl: 'https://facet.localhost:3443',
	auth: staticKey('fct_...')
});
const bookings = facet.domain('rentals').doctype('Booking');

const count = await bookings.list({ aggregate: 'count' });
console.log(count.meta.count);

// An aggregate answer carries the bag in `data.value`, not the row array.
const stock = facet.domain('equipment').doctype('Item');
const agg = await stock.list({ aggregate: 'sum', field: 'purchase_price' });
const bag = agg.data as unknown as { value: Record<string, string> };
console.log(bag.value); // { EUR: '72076.00' }

const mine = await facet
	.domain('clients')
	.doctype('Company')
	.list({ scope: 'my_clients', select: ['name'] });

const children = await facet
	.domain('clients')
	.doctype('Company')
	.doc('06H1FM1B3MXBPS0JYVM3BDD154')
	.children('contacts')
	.list({ items: 50 });
```

Tom's role carries the `my_clients` named scope, so `mine` returns his five
companies and nobody else's.

For faster reads, set `cache: true` on the client. Every `GET` then stores
the strong ETag validator, and the next fetch of the same URL sends
`If-None-Match`. A `304` answer serves the cached envelope; a `200` replaces
the entry. Mutating verbs never touch the store. The cache is off by
default; a custom store implements `get`, `set`, and `delete` on a string
key.

## What the token may do

`GET /Api/iam/me` answers for every credential the SDK holds. The manifest
follows the credential: a browser session reads the active role's manifest;
an app token or an app-owned key reads the resolved grant and role. A
doctype that the grant does not name does not exist in that manifest — there
is no `*.*` fallback for app credentials.

```ts
await facet.whoami(); // cached after the first call
await facet.can('update', 'clients.Company'); // 'all' | 'scoped' | 'denied'
await facet.scopes('create', 'clients.Company'); // [] = unrestricted
await facet.refreshRights(); // re-fetch after a role switch or a grant change
```

The answers are advisory. The server re-resolves grant and role on every
request and never reads the manifest back. Use `can` to decide what the UI
shows; never gate security with it. Treat a denied call's `404` or `403` as
the authority. See
[Gate your UI with the manifest](/build/apps/connect/permission-manifest/).

## Files and artifacts

Two ways exist to add a file. Attach it to a create or an update, or upload
it standalone and link the id. An upload alone gives no read access to
others. An artifact becomes readable when its id is stored in a `file` field
or linked as `urn:facet:artifact:<id>` in a longtext:

```ts
import { createFacetClient, staticKey } from '@facetapp/sdk';

const facet = createFacetClient({
	baseUrl: 'https://facet.localhost:3443',
	auth: staticKey('fct_...')
});

const blob = new Blob(['Signed contract, season 2026'], { type: 'text/plain' });
const uploaded = await facet.artifacts.upload(blob, { filename: 'contract-2026.txt' });
console.log(uploaded.id);

const meta = await facet.artifacts.show(uploaded.id);
console.log(meta.mime_type, meta.size, meta.sha256);

// A signed URL for a reader outside Facet.
const grant = await facet.artifacts.grant(uploaded.id);
console.log(grant.url, grant.expires_at);

// Revoke it when the reader is done.
await facet.artifacts.revoke(grant.grant_id);

// An <a href> / <img src> URL that re-enters the gateway per click.
const href = facet.artifacts.downloadUrl(uploaded.id);

const bytes = await facet.artifacts.download(uploaded.id);
console.log(bytes.byteLength);
```

A grant is ephemeral; the server derives its lifetime from the media type —
about an hour for documents and images, six for audio and video.
`downloadUrl` builds the URL with no network call. Attach-on-write takes an
options bag on `create` and `update`:

```ts
await companies.create({ name: 'Café des Sports' }, { files: { logo: file } });
await doc.update({ name: 'Café des Sports' }, { files: { 'items[0].file': file } });
```

See [Upload and serve files](/build/apps/data/files/) for the model.

## Realtime

One lazy socket to `/Ws` multiplexes every subscription. `facet.realtime()`
opens it on the first subscribe. Frames are hints, never document state. The
server sends no replay: re-fetch what you subscribe to.

```ts
import { createFacetClient, staticKey, type WsFrame } from '@facetapp/sdk';

const facet = createFacetClient({
	baseUrl: 'https://facet.localhost:3443',
	auth: staticKey('fct_...')
});

facet.realtime().onRefusal((error) => {
	console.error('realtime refused:', error.message);
});

const stop = await facet.realtime().subscribe('/clients/Company', (frame: WsFrame) => {
	console.log(frame.event, frame.payload.id);
});

facet.realtime().onReconnect(() => {
	console.log('socket re-opened — refetch your list');
});

setTimeout(() => stop(), 60_000);
facet.realtime().close();
```

The `subscribe` promise settles on the first server message the handle
traces to the path. An in-band error frame — a rights denial or a
subscription over the server cap — rejects it. A matching data frame
resolves it. On a quiet channel it stays pending; do not await it when that
matters; the handler receives frames regardless. Close codes are signals:

| Close code | Behaviour |
| --- | --- |
| `4401` | The handle refreshes the credential once and reconnects. A failed refresh raises `AuthError`. |
| `4403` | The origin is not allowlisted. The handle raises `AuthError` with no retry. |

Browsers offer `["facet-ws-v1", accessToken]` on the subprotocol list. Node
20 has no global WebSocket; there, pass a header-capable constructor. The
credential is then sent in the `Authorization` header of the upgrade request:

```ts
import { WebSocket } from 'ws'; // npm i -D @types/ws
import type { RealtimeWebSocketConstructor } from '@facetapp/sdk';

const rt = facet.realtime({ WebSocket: WebSocket as unknown as RealtimeWebSocketConstructor });
```

See [Live updates](/build/apps/data/realtime/) for the frame grammar and the
channel paths.

## Errors

One base class exists, so app code branches on the class; `UsageError` is
not an `ApiError`.

| Class | Raised on | Extra data |
| --- | --- | --- |
| `ApiError` | any failed exchange | `status`, `message`, `details`, `meta` |
| `AuthError` | missing credential, or a failed refresh or a refused socket credential | re-login hint message |
| `NotFoundError` | `404` — the backend denies with `404`, so it never discloses existence | — |
| `DeletedError` | `410` tombstone | `displayName`, `deletedAt` |
| `NetworkError` | `fetch` threw; the request never reached the server | — |
| `UsageError` | the SDK refused the call locally — bad params, closed handle. Not an `ApiError`; no exchange happened | — |

`details` carries the structured validation items: `field`, `message`,
`code`, and `params`.

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

Facet re-checks the key and the app document on every request; a revoked key
or a disabled app answers `401`. Issue a new key — see
[Service accounts for backend apps](/build/apps/connect/backend-apps/).

**A count call raises `UsageError`.**

`aggregate: 'count'` with `page` or `items` is refused before any network
call. Drop the paging parameters.

**The socket closes with `4403`.**

The origin is not on the allowlist. Register it — see
[CORS and allowed origins](/build/apps/connect/cors/).

**A call answers `NotFoundError` for a document that exists.**

Row scopes on the role or a missing grant hide the row; a `404` never
discloses existence. Check `facet.can('read', 'clients.Company')` — see
[Gate your UI with the manifest](/build/apps/connect/permission-manifest/).

## Related

- [Use the REST API](/build/apps/data/rest-api/) — the HTTP surface the SDK wraps.
- [User login: OAuth 2.1 + PKCE](/build/apps/connect/user-login/) — the browser sign-in flow in full.
- [Live updates](/build/apps/data/realtime/) — the frame grammar behind `realtime()`.
- [Upload and serve files](/build/apps/data/files/) — the artifact model, grants, and publishing.
- [Gate your UI with the manifest](/build/apps/connect/permission-manifest/) — the manifest behind `whoami`.
- Internals on GitHub: [packages/sdk/README.md](https://github.com/wearefacet/facet/blob/main/packages/sdk/README.md).
