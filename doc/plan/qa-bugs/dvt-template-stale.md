# Document view template (DVT) editor does not refresh after edits or navigation

| Field | Value |
| --- | --- |
| Issue | `quality-assurance.Issue` `06H0CZGE009B9S4RS6N784BH2G` |
| Verified | 2026-11-23 — code cross-check on the 0.2.0-beta working tree |
| Area | frontend (builder / configure doctype views) + backend event publisher |
| Verdict | Confirmed. One correction: the editor edits JSON, not YAML |

## Summary

The document view template editor keeps a stale template after external edits
(assistant writes, a second tab) and after in-app navigation. Only a full page
reload shows the new template. Three independent layers each cause this on
their own.

Correction to the report: the editor edits a JSON document, not YAML — the
textarea is `id="dvt-template-json"` (`DoctypeViewsTab.svelte` L243-249). YAML
exists only in the domain import/export bundles. The staleness claims hold
regardless.

## Evidence

1. TTL cache with no external invalidation. The template list loads through
   `doctypeViewsCache` (60 s TTL, keyed by the parent doctype id —
   `clientCache.ts` L189-191) via `loadDoctypeViewsWithIds`
   (`loadDocumentView.ts` L48-64), called from
   `frontend/src/routes/Builder/[draftDomain]/[doctype]/+layout.ts` L29, L46.
   The only invalidator in the whole frontend is the tab's own save
   (`DoctypeViewsTab.svelte` L180-182). External writes never drop it. The
   Configure surface adds a wrinkle: its load `$effect` keys only on
   `slug`/`dt` (`Configure/domains/[slug]/doctypes/[dt]/+page.svelte` L44-61),
   so it ignores `invalidateAll()`.

2. No realtime path exists for templates. `builderSocket.svelte.ts` L66-69
   subscribes only `/core/Domain/{draftId}` and `/core/DocType` — no
   `core.DocumentView` channel is subscribed anywhere in the app. The backend
   cannot bridge the gap: `src/event/publisher.cr` L241 skips the whole `core`
   domain (`return if domain == "core"`) and L215-218 skips the collection
   channel, so a template edit produces no frame any frontend handler
   consumes. `handleWsModelChange` never fires for template edits.

3. The mounted editor freezes its props. `DoctypeEditor.svelte` L344-349:

   ```js
   let views = $derived(untrack(() => viewsProp));
   let viewIds = $derived(untrack(() => viewIdsProp));
   ```

   A zero-dependency `$derived(untrack(...))` never re-evaluates (verified
   against the compiled Svelte 5.56.3 output). Even when the layout load
   re-runs with fresh data, the mounted editor keeps the old templates, and
   `DoctypeViewsTab` keeps copying the frozen prop into local state
   (L98-103). The same pattern sits on `activeTab` (L155).

The live workspace show page (which renders the template) shares the cache,
and its socket filter rejects `child_changed` events
(`documentSocket.svelte.ts` L46-50).

## Root cause

Correctness of the template editor depends on a cache that nothing external
invalidates, on events that are never emitted for `core` children, and on
props frozen at mount.

## Fix direction (order of leverage)

1. `DoctypeEditor.svelte` L344-349 — make `views`/`viewIds` follow the prop
   (tracked derived, or `$state` plus a sync effect guarded by a save-version
   counter so a local post-save override survives).
2. Drop `doctypeViewsCache` in `rebuildDraftNav()` / `handleWsModelChange`, or
   subscribe a `/core/DocumentView` channel in the builder and configure
   surfaces.
3. Optionally invalidate the cache in the assistant chat write path after view
   writes.

Architectural note: the `$derived(untrack(...))` pattern silently converts
props into mount-time constants. Worth a look beyond this fix.
