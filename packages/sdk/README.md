# @facetapp/sdk

TypeScript SDK for Facet. A Facet app imports it to query a Facet instance over HTTP and to subscribe to document changes over WebSocket. It covers documents, queries, actions, child collections, sidecars, aggregates, history, rollback, restore, backrefs, realtime, artifacts, and the caller's permission manifest (`whoami` / `can` / `scopes` / `assistant`).

Zero runtime dependencies. It targets browsers and Node >= 20 with the global `fetch`.

## Install

```sh
pnpm add @facetapp/sdk
```

## Sign in

Two caller channels exist. The SDK serves both; effective reach is always grant ∩ role, re-resolved per request by the backend.

**Backend app (Node, machine): a static `fct_` key.**

```ts
import { createFacetClient, staticKey } from '@facetapp/sdk';

const facet = createFacetClient({
	baseUrl: 'https://facet.example.com',
	auth: staticKey(process.env.FACET_API_KEY!)
});
```

**Browser app: OAuth Authorization Code + PKCE.**

```ts
import { createFacetClient, oauthBrowser } from '@facetapp/sdk';

const auth = oauthBrowser({ slug: 'my-app', redirectUri: `${location.origin}/callback` });
const facet = createFacetClient({ baseUrl: 'https://facet.example.com', auth });

// Once, on a sign-in route:
await auth.signIn(); // navigates to the consent screen; the consent screen elects the role

// On the redirect route:
await auth.handleCallback(location.href);

// The provider attaches the access token and refreshes once on a 401.
// The refresh token rides localStorage; the access token stays in memory.
```

A failed refresh raises `AuthError` with a re-login hint. Concurrent 401s share one refresh call; a `429 slow_down` answer waits the server floor and retries once.

## Documents and queries

```ts
const companies = facet.domain('crm').doctype('Company');

const page = await companies.list({
	filters: { status__eq: 'active', created_at__gte: '2026-01-01' },
	sort: ['-updated_at'],
	items: 50
});
const next = await page.next(); // null when meta.more is false
const total = await companies.list({ aggregate: 'count', filters: { status__eq: 'active' } });

const doc = companies.doc(id);
await doc.show();
await doc.update({ status: 'archived' });
await doc.action('archive', { reason: 'done' });
await doc.history();
await doc.rollback(mutationId);
await doc.restore(); // undelete a tombstone
await doc.backrefs();
await doc.children('contacts').list();
await doc.sidecars('comments').list();
await companies.create({ name: 'Acme' });
await companies.create({
	$content: { name: 'Acme' },
	$children: { career_events: [{ event_type: 'hired' }] }
});
```

`list` params mirror the backend `ListRequest` grammar: `page`, `items` (1..1000), `filters` with raw `field__op` keys, `sort` (`-` prefix = descending), `aggregate` + `field`, `scope`, `select`, and `includeDeleted`. The SDK clamps paging and refuses unknown operators or `count` with paging locally — with a `UsageError`, before any network call.

## What the token may do

```ts
const me = await facet.whoami(); // GET /Api/iam/me — cached after the first call

const answer = await facet.can('read', 'crm.Company'); // 'all' | 'scoped' | 'denied'
const aliases = await facet.scopes('create', 'crm.Company'); // scope aliases; [] = unrestricted
await facet.refreshRights(); // re-fetch after a role switch or grant change

const assistant = await facet.assistant(); // { access, token_budget, name }
if (assistant.access) {
	FacetAssistant.open({ baseUrl, fetch: hostFetch, appId });
}
```

`GET /Api/iam/me` answers for every credential the SDK holds: a session token, an OAuth app token, or a static `fct_` key. The `permissions` manifest follows the credential — a session token reads the active role's manifest; an app token or an app-owned key reads the resolved grant ∩ role, so a document the app's grant does not name does not exist in it: no `*.*` fallback, no doctype outside the grant.

`can` matches that manifest locally: exact key → concrete ancestors (`crm.Contact` reaches `crm.Contact.Comment`) → domain wildcard → `*.*`, subtracting the folded `{key}.except.{action}` carve-outs. `'all'` is unrestricted; `'scoped'` is granted with scope aliases (read them with `scopes` — `[]` means unrestricted); `'denied'` means no manifest key reaches the path.

The answers are advisory. The server re-resolves grant ∩ role on every request and never reads the manifest back — size affordances with `can`, never gate security with it, and treat a denied call's 404/403 as the authority. `whoami` caches after the first call; `refreshRights` re-fetches when the reach may have moved (a role switch on the consent screen, a grant edit).

The `assistant` block gates the embeddable chat (`@facetapp/chat`): `access` is the role's `assistant_access`, ANDed for an app token with the app's own `assistant_enabled` flag — the same gate the conversation create route applies. A `false` answer means the denial panel would render; hide the launcher instead.

## File fields and artifacts

```ts
// Attach: one multipart call. The uploads and the mutation share one
// server-side transaction.
await companies.create({ name: 'Acme' }, { files: { logo: file } });
await doc.update({ name: 'Acme' }, { files: { 'items[0].file': file } });

// Standalone upload, then link the id or the URN.
const { id, filename } = await facet.artifacts.upload(file);
await facet.artifacts.uploadAsUrn(file); // urn:facet:artifact:<id> for longtexts

// Read URLs for someone with no session.
const grant = await facet.artifacts.grant(id); // ephemeral; the server derives the TTL
const meta = await facet.artifacts.show(id);
await facet.artifacts.revoke(grant.grant_id);

// A permanent public URL needs the publish_artifact action on an owner
// document; the provenance row binds the grant.
await facet.artifacts.publish(id, { ownerId });

// <a href> / <img src>: the gateway mints a fresh grant per request.
facet.artifacts.downloadUrl(id);
facet.artifacts.downloadUrl(id, { appId }); // app-origin reads
const bytes = await facet.artifacts.download(id); // follows the 302, returns the bytes
```

Uploading alone grants nothing to others. An artifact becomes readable when its id lands in a `file` field or a `urn:facet:artifact:` link in a longtext.

## Realtime

```ts
const rt = facet.realtime();

const offReconnect = rt.onReconnect(() => reloadList());
const offRefusal = rt.onRefusal((error) => hideLiveUi(error));
rt.subscribe('/crm/Company', (frame) => refetch(frame.payload.id)).catch(() => {});
const off = await rt.subscribe(`/crm/Company/${id}`, handleDocFrame);

await rt.ensureConnected(); // optional: open the socket now
rt.close(); // stops the handle
```

One lazy socket to `/ws` multiplexes every subscription. On a drop the handle reconnects with a capped backoff. It re-sends every active subscription. Then it fires the reconnect handlers. The server delivers no replay: re-fetch what you subscribe to. The frames are hints, never document state.

The subscribe promise settles on the first server message the handle can trace back to the path. An in-band error frame — an RBAC denial or an over-cap answer — rejects it. A matching data frame resolves it. On a quiet channel it stays pending. Do not await it when that matters; the handler receives frames regardless.

A refusal — the in-band error frame, a `4401`/`4403` close, a failed token refresh — rejects the subscribe promise and fires every `onRefusal` handler with that same error, once per refusal. Register `onRefusal` to react: hide live UI, re-auth, log. The promise rejection stays real either way, so a fire-and-forget `subscribe` carries a `.catch(() => {})`; without it the host app logs an unhandled rejection on top of the handler signal.

The credential rides the handshake per transport. Browsers offer `["facet-ws-v1", accessToken]` on the subprotocol list. Node 20 has no global WebSocket. There, pass a header-capable constructor. The credential then rides the `Authorization` header of the upgrade request; static `fct_` keys are accepted there:

```ts
import { WebSocket } from 'ws'; // npm i -D @types/ws
const rt = facet.realtime({ WebSocket: WebSocket as unknown as RealtimeWebSocketConstructor });
```

Close codes are signals. `4401` refreshes the token once and reconnects; a failed refresh raises `AuthError`. `4403` — the origin is not allowlisted — raises `AuthError` with no retry. A refusal fires the `onRefusal` handlers.

## ETag cache

```ts
const facet = createFacetClient({ baseUrl, auth, cache: true });
```

With the cache on, every GET stores the response's strong ETag validator. The next fetch of the same URL sends `If-None-Match`. A `304` serves the cached envelope without a re-parse. A `200` replaces the entry. Mutating verbs never touch the store. Default: off. A custom store rides instead of `true` — implement `get`/`set`/`delete` on a string key.

## Errors

One base class, so app code branches without reading strings:

| Class           | Raised on                                                                                           | Extra data                             |
| --------------- | --------------------------------------------------------------------------------------------------- | -------------------------------------- |
| `ApiError`      | any failed exchange                                                                                 | `status`, `message`, `details`, `meta` |
| `AuthError`     | missing credential, or a failed refresh / refused socket credential                                 | re-login hint message                  |
| `NotFoundError` | `404` — the backend denies with `404`, so it never discloses existence                              | —                                      |
| `DeletedError`  | `410` tombstone                                                                                     | `displayName`, `deletedAt`             |
| `NetworkError`  | `fetch` threw; the request never reached the server                                                 | —                                      |
| `UsageError`    | the SDK refused a call locally — bad params, closed handle. Not an `ApiError`; no exchange happened | —                                      |

`details` carries the server's structured validation items (`field`, `message`, `code`, `params`).

## License

BUSL-1.1 — see [LICENSE](./LICENSE).
