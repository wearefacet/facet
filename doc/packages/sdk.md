# SDK — `@facetapp/sdk`

The TypeScript SDK for Facet apps. It wraps the Facet HTTP API and the WebSocket real-time bridge for code running outside Facet — browser apps served by `App::Hosting` and backend apps on Node. It has its own `package.json` and lockfile, and no workspace file at the repo root.

> **Source-only for now.** `@facetapp/sdk` is not on the npm registry yet — `npm view @facetapp/sdk` answers `404`. The install line in [`packages/sdk/README.md`](../../packages/sdk/README.md) resolves once a maintainer publishes the package by tag (see [`release.md`](release.md)). Until then, consume the source under `packages/sdk/` directly.

Publishing the package to npm is a separate concern: see [`release.md`](release.md).

## Source files

All paths are relative to `packages/sdk/`:

| File | Role |
| ---- | ---- |
| `src/index.ts` | Public exports only |
| `src/http.ts` | `requestJson` / `requestBytes`: base URL join, bearer header, JSON and multipart bodies, typed error mapping, 401 refresh-and-retry, byte downloads |
| `src/errors.ts` | `ApiError` + typed subclasses (`AuthError`, `NotFoundError`, `DeletedError`, `NetworkError`) and `UsageError` for local refusals |
| `src/query.ts` | `ListParams` + `serializeListParams`: the `ListRequest` grammar as a query string, clamped and validated locally |
| `src/client.ts` | `createFacetClient`, the domain → doctype → document handle tree, multipart file fields, the `artifacts` and `realtime` factories |
| `src/cache.ts` | ETag store interface + the in-memory default |
| `src/auth/provider.ts` | `TokenProvider` interface + `staticKey` |
| `src/auth/oauth.ts` | `oauthBrowser`: PKCE sign-in, callback exchange, single-flight refresh with the `slow_down` floor |
| `src/auth/storage.ts` | `TokenStorage` / `FlowStore`; the browser default keeps the access token in memory and the refresh token in `localStorage` |
| `src/realtime.ts` | `facet.realtime()`: one lazy socket to `/Ws`, subscriptions, reconnect, close-code mapping |
| `src/artifacts.ts` | `facet.artifacts`: upload, metadata, grants, revoke, download gateway |
| `src/multipart.ts` | File-part naming shared by uploads and file fields |

User-facing documentation lives in [`packages/sdk/README.md`](../../packages/sdk/README.md) — it ships in the npm tarball. This doc covers the module layout and the contracts behind it.

## Layering

```
client.ts ──> http.ts ──> fetch (one request; 401 → refresh → retry once)
    │             │
    │             └──> cache.ts (GET only: If-None-Match / 304)
    ├──> query.ts     (list params → URLSearchParams, local refusals)
    ├──> realtime.ts  (one WebSocket, token per dial, resubscribe on reconnect)
    └──> artifacts.ts (multipart upload, grants, byte download)
auth/oauth.ts ──> auth/storage.ts (tokens + sign-in flow state)
```

- The handles mirror the frontend datasource (`frontend/src/lib/datasource/interface.ts`) one-for-one: same method names, same `ListParams`, same `{data, meta}` envelopes. The realtime handle mirrors `frontend/src/lib/websocket.svelte.ts`. The artifact helpers mirror `frontend/src/lib/artifacts.ts`. The shape match is deliberate — no shared code, no Svelte dependency.
- `http.ts` maps non-2xx bodies (`{error, details[]}`) into typed errors. A `404` maps to `NotFoundError`. A `410` maps to `DeletedError` with `display_name`/`deleted_at` from the body. Other statuses map to `ApiError`. A fetch throw maps to `NetworkError`.
- `query.ts` refuses locally with `UsageError`: unknown `__op` suffixes, `page`/`items` with `aggregate: 'count'`, paging outside the backend bounds. The backend stays the validator of record for which operator serves which field family.
- `cache.ts` is off by default. A GET with a stored validator sends `If-None-Match`; any `304` serves the stored envelope (the backend emits strong validators only). Mutating verbs never read or write the store.
- `auth/oauth.ts` resolves the client id through the public `client-info` route. It builds the authorize URL with PKCE S256 and exchanges the callback code. The refresh runs single-flight: concurrent 401s join one call. A `429 slow_down` answer waits the 10-second floor and retries once. The consent screen elects the role — no `role` parameter exists on this surface.
- `realtime.ts` multiplexes all subscriptions over one lazy socket. The credential rides the handshake per transport: subprotocol entries `["facet-ws-v1", accessToken]` on the browser transport. An injected header-capable constructor carries an `Authorization` header instead — Node 20 has no global WebSocket, and static `fct_` keys are accepted there but rejected on the subprotocol transport. The token is pulled from the `TokenProvider` at every dial. On a drop the handle reconnects with a capped backoff (1 s × 1.5 to 10 s, reset on a successful open). It re-sends every active subscription, then fires the reconnect handlers. Close codes are signals: `4401` refreshes the token once and reconnects; a failed refresh raises `AuthError`. `4403` raises `AuthError` with no retry. In-band error frames (`{error, path}`) reject the matching `subscribe()` promise; the socket stays open. The server sends no subscribe acknowledgement, so the promise settles on the first attributable server message — a matching data frame resolves it. Frames are hints: the handle passes `{channel, event, payload, headers}` to the handler and caches nothing.
- `artifacts.ts` uploads one multipart `file` part to the standalone route and projects the answer to `{id, filename}`. `grant` mints an ephemeral signed URL; the server derives the TTL from the media type — no client-side TTL. `publish` mints a permanent grant against the provenance row the caller names (`owner_id` is a server requirement). `download` follows the gateway `302` and returns the bytes. `downloadUrl` builds the `?app=` gateway URL with no network call.

## Backend contract

| Call | Backend surface |
| ---- | ---- |
| Documents, queries, actions, children, sidecars | `/Api/:domain/:doctype` list/create/read/update/delete, `…/:id/:segment` sub-collections, `…/:id/:action` |
| History, rollback, restore, backrefs | `GET …/:id/history`, `POST …/:id/rollback`, `POST …/:id/restore`, `GET …/:id/backrefs` |
| ETag validators | strong `ETag` on single-document and collection GETs; `If-None-Match` → `304` |
| Tombstones | `410` with `display_name` + `deleted_at` in the body |
| OAuth | `GET /OAuth/client-info?slug=…` (public), `GET /OAuth/authorize`, `POST /OAuth/token` (both grants) |
| Realtime | `GET /Ws` upgrade; `subscribe`/`unsubscribe` frames; close codes `4401`/`4403`; in-band `{error, path}` frames |
| Artifacts | `POST /Api/core/artifacts` (multipart), `GET …/:id`, `POST …/:id/grant`, `POST …/:id/publish`, `DELETE /Api/core/artifacts/grants/:gid`, `GET …/:id/download` (`302` to the signed serve URL) |
| File fields | multipart create/update: a `$content` part plus one part per `file` field keyed by the normalized field path |

Out of scope for the SDK: the operator artifact surface (`/Api/Artifacts`, purge), the app deploy flow, the agent signed-upload route (`/A/upload/:uid`), and the `/notifications` self-subscription (the backend refuses it to app-scoped principals).

## Testing

Vitest, `pnpm test` inside `packages/sdk`. The module tests mock `fetch` (and the WebSocket constructor for realtime) and cover: URL join and bearer headers, error mapping with string and `{message}` details, the 204/empty-body paths, every documented `__op` suffix, clamp and refusal edges, handle routes and verbs, `next()` paging, cache hits and misses, the PKCE pair and authorize URL shape, single-flight refresh and `slow_down`, the realtime handshake forms, frame dispatch, resubscribe order, close-code mapping, in-band error frames, the upload request shape, the field-path part names, the grant/publish/revoke routes, and the download redirect.
