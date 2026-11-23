# No delete affordance for collection views in the workspace UI

| Field | Value |
| --- | --- |
| Issue | `quality-assurance.Issue` `06H0D3XJNGKJ698VPZZ3TAEQ3Z` |
| Verified | 2026-11-23 — code cross-check on the 0.2.0-beta working tree |
| Area | frontend (workspace view tabs, view editor) |
| Verdict | Confirmed for the workspace UI. Refuted for the assistant surface |

## Summary

The workspace view tab strip offers create, pin, and edit only. There is no
way to delete a saved collection view. The delete path exists end to end —
REST route, soft-delete service, frontend driver, last-view safety rails — but
no affordance is wired to it.

Correction to the report: the assistant surface is not part of the gap. The
domain-builder already has a `delete_collection_view` tool.

## Evidence

The gap (workspace UI):

- `frontend/src/lib/components/primitives/data/ListView.svelte` L485-547 — the
  tab action area renders exactly three affordances: create (L486-504),
  pin/unpin (L506-511), edit (L527-531). No delete.
- `frontend/src/lib/components/primitives/navigation/Tabs.svelte` L26-33 — tabs
  support only `icon`, `trailing`, and `children` snippets; no per-tab menu.
- `frontend/messages/en.json` L1495-1504 — keys `list_view_default`, `create`,
  `pin`, `unpin`, `edit`, `save_default`, `views_loading`. No delete key exists
  anywhere.
- `frontend/src/lib/components/primitives/data/CollectionViewEditor.svelte` —
  create/update only (`handleSave` L253-291; footer L420-434 renders Cancel,
  Back, Save/Create).

The path is already built (unwired):

- REST child delete route: `src/http/rest_routes.cr` L641 (soft-delete through
  the composition path).
- `Document::Delete` preflight `src/document/delete.cr` L181-210 — no
  CollectionView special case. `data/seeds/core.CollectionView/script.lua`
  defines create and update hooks only — no delete hook.
- Frontend driver: `DocumentDataSource.ts` L142-147 (`ConcreteDocumentRef.
  delete`) and `ChildScopedDataSource.doc` L258-260.

Last-view safety (answers the guardrail questions in the issue):

- The UI falls back to a synthetic "Default" tab when no views exist
  (`ListView.svelte` L207-211; the comment at L258-260 names "all views
  deleted" explicitly).
- The boot seed re-creates a default view for a doctype with zero live views
  (`src/doctype/seed.cr` L711-762; the existence check filters
  `AND deleted_at IS NULL`, L739). Re-seed happens at next boot; the synthetic
  tab covers the interim.
- Soft delete is recoverable through audit replay, as the issue notes.

Assistant surface (refuted part):

- `src/assistant/domain_builder/tools/write_tools.cr` L329-349 registers
  `delete_collection_view` ("Soft-delete a CollectionView. The view must belong
  to a doctype in the draft domain..."). It is in the tool catalogue
  (`tools.cr` L62-68) and registered (L112-118). `doc/backend/assistant.md`
  L346 lists it.

## Root cause

The view tab strip and the view editor were built create/update-only. Server,
route, driver, and safety rails are all present.

## Fix direction

`ListView.svelte` only:

- Add a delete `IconButton` in the `trailing` snippet, gated on
  `<Can doctype="core.CollectionView" action="delete">`, shown when
  `activeView` exists.
- Add a confirm dialog. After delete: invalidate `collectionViewsCache`, bump
  `refreshKey` (mirror `handleSaved`, L427-436).
- Add `list_view_delete` i18n keys (en + fr).

No backend change is needed.
