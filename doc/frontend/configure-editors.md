# Configure editors — Builder schema editing

The doctype and domain editors behind the Builder routes (and their readonly
mirrors under `/Configure/domains/…`). Each editor owns a working copy of the
definition, edits it through child components with explicit prop contracts,
and saves through the doctype/domain REST endpoints. The collection-view
editor is a separate concern — see
[`../backend/collection-view.md`](../backend/collection-view.md) → Frontend
consumption.

The domains landing page (`/Configure/domains`) accepts the `?import=1`
deep link: on mount it opens the import dialog and strips the param, so the
welcome tour and the dashboard's empty-state card can link straight into the
import flow.

## Source files

| File                                                                   | Role                                                                                                                                                        |
| ---------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `src/lib/components/features/configure/DoctypeEditor.svelte`           | Doctype editor shell — working copy, tab state, selection, save/draft/delete                                                                                |
| `src/lib/components/features/configure/DoctypeEditorHeader.svelte`     | Breadcrumbs, identity row, save flash, draft banner, tab bar                                                                                                |
| `src/lib/components/features/configure/DoctypeChildrenTab.svelte`      | Children pane — entries mutated in place, add/delete via callbacks                                                                                          |
| `src/lib/components/features/configure/DoctypeActionsTab.svelte`       | Actions pane incl. argument rows                                                                                                                            |
| `src/lib/components/features/configure/DoctypeLogicTab.svelte`         | Lua script editor + exported-symbols list                                                                                                                   |
| `src/lib/components/features/configure/DoctypeSettingsTab.svelte`      | General tab — identity form (label, plural label, icon, color, description editable without a draft when the host grants it), schema-migration map (version → Lua function, validated against the script's exports), shared `DangerZone` |
| `src/lib/components/features/configure/DoctypeViewsTab.svelte`         | View-kind nav + preview, with a Display / Edit toggle over a JSON template editor (writer-only)                                                              |
| `src/lib/components/features/configure/DoctypeFieldList.svelte`        | Fields pane list                                                                                                                                            |
| `src/lib/components/features/configure/DoctypeFieldEditor.svelte`      | Selected-field editor                                                                                                                                       |
| `src/lib/components/features/configure/DomainEditor.svelte`            | Domain editor shell — domain doc load, grant documents + context sets, save/drop                                                                             |
| `src/lib/components/features/configure/DomainEditorHeader.svelte`      | Crumb, identity row with draft badge, save flash, tab bar                                                                                                     |
| `src/lib/components/features/configure/DomainOverviewTab.svelte`       | Label, color, Markdown description; the domain id stays read-only (the publish dialog owns the target name for drafts)                                        |
| `src/lib/components/features/configure/DomainDoctypesTab.svelte`       | Doctype list + schematic                                                                                                                                      |
| `src/lib/components/features/configure/DomainEditorsTab.svelte`        | Editors pane — the `core.DomainEditor` grant list: add/remove accounts (admin-only affordances), read-only otherwise; reuses `RoleMemberRow`                   |
| `src/lib/components/features/configure/DomainGrantsTab.svelte`         | Grants pane — issued `core.DomainGrant` documents (resources editor + activate/deactivate) and the read-only held-access list; affordances `can()`-gated       |
| `src/lib/components/features/configure/DomainContextSetCard.svelte`    | One context-set card incl. where rows                                                                                                                         |
| `src/lib/components/features/configure/DomainCheck.svelte`             | Draft-only diagnostics tab                                                                                                                                    |
| `src/lib/components/features/configure/domainSecurity.ts` + `.spec.ts` | Context-set helpers: `contextSetRowsFromMap`, `composeContextSets`                                                                                            |
| `src/lib/components/features/configure/domainGrants.ts` + `.spec.ts`   | Pure grant model: wire types (`DomainGrantContent`, `GrantTicket`), resource working-copy rows (`resourceRowsFrom` / `composeResourceRows` / `resourceRowsError`), `grantDomainId`, `ticketPullsUntagged`, `tagsInUse` |
| `src/lib/doctype/keys.ts` + `.spec.ts`                                 | `sanitizeKeyInput` (lowercase, strip, leading-letter rule) and `nextUniqueKey` — shared by both editors' key inputs                                         |
| `src/lib/doctype/iconPicker.svelte.ts` + `.spec.ts`                    | `createIconPicker()` — paged icon search state machine (seq guard, scroll threshold)                                                                        |
| `src/lib/components/primitives/surfaces/DangerZone.svelte` + story     | Type-to-confirm destructive zone shared by both editors                                                                                                     |

## Working-copy contract

- The registry is read-only. The editor builds an isolated working copy
  (`parseDoctypeDef(structuredClone(raw))`) and never resyncs; save serializes
  it back with `serializeDoctypeDef`, round-tripping keys the editor does not
  surface.
- Tab components receive the parent's proxy arrays and mutate **entries** in
  place; add/delete and cross-entry concerns stay in the parent through
  callbacks. Selection is tracked by object reference so a key rename does not
  lose it (read the pushed row back through the proxy after `sort`).
- `color`/`icon`/`label`/`plural_label`/`script` are coerced to `''` on the
  working-copy build — `ColorInput`/`CodeEditor` declare `$bindable` fallbacks
  and Svelte 5 rejects `bind:value={undefined}` (props_invalid_value).
- The active tab is a writable derived over the URL prop with `untrack`;
  `selectTab` sets optimistic state then calls `goto`. Tab order:
  `general`, `fields`, `children`, `actions`, `logic`, `views` — the
  Configure shell relies on the `general` default, the Builder routes
  default to `fields`.

## Views tab

- The tab shows the five `core.DocumentView` kinds (`VIEW_KINDS`: `view`,
  `form`, `inline`, `card`, `quickView`) with a defined/fallback badge, and
  previews the selected kind. A kind with no stored view previews the
  definition-generated fallback (`defaultViewTemplate(def)`); the empty-state
  note says so and points at the Edit mode.
- A **Display / Edit** toggle sits above the preview. Edit replaces the pane
  with a plain `<textarea>` (monospace, no highlighting) holding the view's
  `template` object as pretty-printed JSON — the stored template when one
  exists, the fallback otherwise. Save validates the JSON locally first (an
  inline `role="alert"` error names the parse failure or a non-object root,
  and nothing is sent), then writes the view and returns to Display.
- The write route is the `core.DocumentView` child of the doctype: `PATCH`
  `/Api/core/DocType/<parent>/document_view/<id>` when the kind has a stored
  child id, `POST` `/Api/core/DocType/<parent>/document_view` with
  `{ parent_doctype, kind, template }` when it does not. The parent linkage
  rides the path; the body carries view content only. `viewAuthoring.ts` owns
  both calls and takes an injectable `fetch` (components pass `apiFetch`).
- The child ids come from the same route load as the templates
  (`loadDoctypeViewsWithIds`), passed down as `views` / `viewIds`. After a
  save the component updates its local copies so the preview reflects the new
  template at once, and invalidates `doctypeViewsCache` for the parent so a
  reload does not serve the 60s TTL entry.
- The Edit affordance is a UI hint: it renders only when the editor is not
  `readonly` (a published domain in the Configure shell is read-only) and the
  caller holds `create` or `update` on `core.DocumentView`. The backend
  re-checks every write.

## Save, draft, drop

- Doctype save patches the cached registry entry; delete drops it and
  navigates. Save flashes share `createSaveFlash` (`lib/utils/saveFlash.svelte.ts`).
- **Published metadata edit** — the Configure per-doctype page passes
  `allowMetadataEdit={can('core.DocType', 'update')}`. With `readonly` set
  together with that flag, the General tab's presentation fields (label,
  plural label, icon, color, description) stay editable and the header shows
  Save beside the published note (the draft button steps down to a secondary
  style). The save is a metadata-only same-version PUT — presentation
  metadata is not part of the version gate's data shape, so the live guard
  passes. The transport body strips `migrations` (a live same-version PUT
  must not carry the map; the backend merges the stored one, B-301) while
  the cached registry entry keeps it, so other readers never see it vanish.
  After a save the sidebar label/icon refresh on the next nav rebuild, not
  instantly — the live nav has no `/core/DocType` subscription outside
  Builder/preview.
- Domain save omits `color` when cleared so the backend deep-merge keeps the
  stored value. Drop invalidates `domainListCache` + `documentShowCache`
  before navigation. The `publishName` fallback chain never uses `domain`
  (that is the `_`-prefixed draft id).
- The publish dialog renders the ticket report when a publish filed or
  merged grant tickets — one card per producer (filed/merged line, edge
  list, Active/Awaiting state) and a `Go to {domain}` button as the only
  exit; a publish with no tickets closes the dialog as before.
  `builderDraft.publishDraft` returns the report to the dialog instead of
  navigating, because the draft URL behind it is dead by then.
- The `DangerZone` confirm target is the qualified doctype name or the domain
  id; the busy label differs per surface (`busyLabel`).

## Editors tab

- The editors pane lists the domain's `core.DomainEditor` grant rows — one
  document per (account, domain) pair. The rows are separate admin-managed
  documents, not `core.Domain` content: the parent reads them with a
  `filters[domain__eq]` list call and feeds the tab-count badge; add and
  remove go through the generic document API (`POST`/`DELETE
  /Api/core/DomainEditor[/:id]`), then `onreload` re-reads the list.
- Affordances follow the backend RBAC shape. The editor role carves
  `core.DomainEditor` out of its blanket lines, so add/remove render only
  when `can('core.DomainEditor', 'create' | 'delete')` holds (admin by
  seed); every other role gets a read-only list (`RoleMemberRow` with
  `removable={false}`). System domains never carry rows (the doctype's Lua
  create guard rejects them), so they render a note instead of a picker.
- The tab loads `iam.Account` once for labels and picker candidates — the
  full-account scan mirrors the role members page (mid-sized organizations).
  The picker offers accounts without a grant row, so duplicates cannot be
  created through the UI.

See [`../backend/domain-editors.md`](../backend/domain-editors.md) for the
backend contract.

## Grants tab

- Grants are `core.DomainGrant` **documents**, not domain content. The
  parent loads two lists: the domain's own grants through the child
  collection route (`GET /Api/core/Domain/:id/grants` — the producer side)
  and the tickets filed in this domain's favour through the
  `consumer_domain__eq` reference filter on the flat `core.DomainGrant`
  list (the consumer side). The two lists feed the tab badge
  (`grantCount + contextSetCount` in the header).
- **Issued grants** — one card per grant: consumer label (from the
  qualified `consumer_domain` reference), acceptance badge (`Active` /
  `Awaiting acceptance`), a resources editor (per-doctype tag-mask rows),
  and activate/deactivate. The producer edits `resources` with a working
  copy per card (`workingRows`, keyed by grant id, seeded lazily from the
  document) and saves with a `PATCH` of the `resources` key — the
  `read_only` `active` flag can never ride that patch.
- **Held access** — read-only cards: producer (from `meta.parent_id`),
  acceptance badge, and the per-entry `doctype + tags` mask. The producer
  owns the document, so the consumer side renders no affordances.
- **Acceptance is not a document action.** Activate/deactivate POST to
  `/Api/core/DomainGrant/:id/{activate,deactivate}` — dedicated routes that
  bypass the `read_only` flag. `DocumentRef.action('activate')` reaches
  them (same URL shape; the routes register before the REST catch-all).
  The buttons render only when `can('core.DomainGrant', 'activate' |
  'deactivate')` holds; create/delete/edit gates follow the same manifest
  lookups, so a role without `core.DomainGrant` rights gets the read-only
  pane.
- The create flow posts an empty-resources grant into the producer's
  subtree (`POST /Api/core/Domain/:id/grants` with the qualified consumer
  reference); the backend files it inactive — a ticket awaiting the
  producer's resources and acceptance.
- The doctype field form's tag input doubles as the grant vocabulary:
  `DoctypeEditor` derives the domain's tags-in-use (`tagsInUse` over the
  registry's definitions, same domain prefix) and passes them to
  `DoctypeFieldEditor` as suggestion chips — free-form input stays the
  primary entry; empty means `default`.
