# Drafts list stale after publish (publish path only)

| Field | Value |
| --- | --- |
| Issue | `quality-assurance.Issue` `06H0D10S60DVC58H9DTSQSDBWJ` |
| Verified | 2026-11-23 — code cross-check on the 0.2.0-beta working tree |
| Area | frontend (builder drafts, client caches) |
| Verdict | Confirmed for publish. Discard already self-invalidates |

## Summary

After a draft domain is published, the drafts list, the sidebar, and the
published list keep the pre-publish state until a full page reload. The publish
action performs no local cache invalidation; freshness rides entirely on
at-most-once WebSocket events. The sibling discard action invalidates locally
and does not show the problem in the current code.

## Evidence

Caches:

- `frontend/src/lib/datasource/clientCache.ts` L42 — `TTL_MS = 60_000`;
  module-level state dies only on a full page reload.
- `frontend/src/lib/navModel.ts` L192-198 — the drafts list
  (`buildNavModel({ drafts: true })`) reads `core.Domain` through
  `domainListCache`, a keyless singleton TTL cache (`clientCache.ts` L184).
  Both drafts surfaces use it: `frontend/src/routes/Builder/+page.ts` L28-31
  and `DomainsList.svelte` L80-94. In-app navigation re-runs the load, but the
  cache short-circuits the fetch for up to 60 s.

Publish path (`frontend/src/lib/builderDraft.svelte.ts` L317-359):

- After the POST and `waitForPublishBurst()`, it calls `goto('/Builder')` — and
  nothing else. No `domainListCache.invalidate()`, no
  `doctypeRegistryCache.invalidate()`, no `rebuildDraftNav()`, no
  `invalidateAll()`.

Contrast — the discard path (L266-284) does it right:

```ts
domainListCache.invalidate();
documentShowCache.invalidate(`/Api/core/Domain/${draftId}`);
await goto(resolve('/Builder'));
await invalidateAll();
```

Freshness rides on WebSocket delivery:

- The only invalidation on the publish path is the WS burst handler (root
  `+layout.svelte` L558-561 → `rebuildDraftNav()` drops the caches).
- The socket delivers no replay while disconnected
  (`builderSocket.svelte.ts` L71-72), and the bus is at-most-once by decision.
  Two failure windows are deterministic: event loss or socket down, and the
  settle race (`PUBLISH_BURST_SETTLE_MS` 250 ms — L161, L177-184). Then the
  pre-publish cache entry serves every in-app navigation for up to 60 s. A full
  reload clears module state — the reported workaround.
- The published list on `/Configure/domains` goes stale the same way: the root
  layout load resolves it from `data.domains`, which re-runs only on
  `invalidateAll()`.

## Root cause

`publishDraft` performs no local invalidation; it delegates freshness to
at-most-once WS delivery. The sibling actions (discard, create) invalidate
locally.

## Fix direction

`frontend/src/lib/builderDraft.svelte.ts`, `publishDraft` (L317-359): after the
POST resolves (both return paths), invalidate `domainListCache` and
`doctypeRegistryCache`, and add `await invalidateAll()` after the
`goto('/Builder')` — mirroring `discardDraft` L279-284.

## Correction to the report

The discard half of the report does not reproduce on the current code (see the
discard path above). If a stale draft was observed after discard, it predates
the current invalidation code.
