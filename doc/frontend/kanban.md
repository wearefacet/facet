# Kanban View

The kanban surface shows a listing as horizontal lanes of cards. It is one of the `core.CollectionView` listing surfaces (`surface === 'kanban'`), rendered by `ListView` when the active view carries a `kanban` config. Each lane groups the doctype's documents by a selector; each card renders through the doctype's `card` document-view template. Values-mode boards can order and hide lanes per view, and — when the view opts in — cards move between lanes through drag and drop (see [Moves](#moves)).

## Source files

- `frontend/src/lib/kanban/Kanban.svelte` — surface shell: lane resolution (with the values-mode overrides), per-lane fetch orchestration, drag-and-drop move orchestration, card-template load, empty state.
- `frontend/src/lib/kanban/KanbanLane.svelte` — one lane: header (colour dot, label, count badge), scrollable card stack, Show more, drop-target highlight, empty/error state.
- `frontend/src/lib/kanban/KanbanCard.svelte` — one card: identity head (doctype icon, display name, updated time), the bounded DVT body, and the drag handle.
- `frontend/src/lib/kanban/lanes.ts` — pure lane logic: `lanesFromGroupBy` (values mode), `groupByLaneKeys`, `laneKey`, `applyLaneOverrides`, `mergeLaneFilters`, `laneWriteTarget`, `validateLanes`.
- `frontend/src/lib/kanban/lanes.spec.ts` — Vitest `server` project tests for the pure logic.
- `frontend/src/lib/kanban/Kanban.stories.svelte` — Storybook stories (component tests) for both modes, the card template and fallback, pagination, and money buckets.
- `frontend/src/lib/components/primitives/data/CollectionViewKanbanForm.svelte` — the view editor's kanban form (board mode, lanes, sort, base filter).
- `frontend/src/lib/collectionView/types.ts` — `KanbanLane`, `KanbanViewConfig`.

## Lane model

A lane is the single runtime model for both authoring modes:

```ts
interface KanbanLane {
  label: string;
  color?: string; // hex; falls back per value/label
  filter: Record<string, unknown>; // field__op → value
}

interface KanbanViewConfig {
  mode: "values" | "custom";
  group_by?: string; // values mode
  lane_order?: string[]; // values mode; lane keys in display order
  hidden_lanes?: string[]; // values mode; lane keys not rendered or fetched
  lanes?: KanbanLane[]; // custom mode; render order = array order
  filters?: Record<string, unknown>; // view-level base filter
  sort?: string[]; // ListParams.sort format
  page_size?: number; // per-lane fetch cap
  allow_move?: boolean; // drag & drop between lanes; absent = off
}
```

- **Values mode** derives the lanes from the `group_by` field's declared values at render time. The group-by picker (`groupableFields`) offers writable `enum` and `boolean` fields. On an enum, one lane per declared value, declaration order; `label = value.label ?? humanize(key)`, `color = value.color ?? hashColor(key)`, and the lane filter is `{ "<group_by>__eq": value }`. On a boolean, the two lanes True and False (localized through the filter-bar words), `color = hashColor('true' | 'false')`, and the lane filter emits the wire strings `true` / `false` — the same form the backend text path parses. The humanize step mirrors the table: a declared label wins, and a value with no label shows the humanized key. The `field__eq` key form keeps the lane filter identical in shape to what the backend and the mock both parse, and it keeps the group-by rename-safe.
- **Custom mode** stores the explicit lane list. Custom lanes may overlap or leave gaps — a document can appear in more than one lane. That is config-owned behaviour, not an error.

### Values-mode lane overrides

A values-mode view can persist a presentation over the derived lanes: `lane_order` (the value keys in display order) and `hidden_lanes` (the value keys whose lanes neither render nor fetch — their documents show nowhere on the board). `applyLaneOverrides(derived, lane_order, hidden_lanes)` applies both: hidden lanes drop out, the rest sort into the stored order, and any key the order does not list keeps declaration order after the listed ones. Stale keys (the enum changed since the view was saved) are ignored, so the board always renders every visible derived lane — a config the renderer cannot fully resolve never blanks the board. A lane's key is the value its single `field__eq` filter matches (`laneKey`); a boolean group-by uses the wire strings `true` / `false`.

`buildConfig` persists the keys only against the group-by field's current declared values — it appends unlisted keys, drops stale ones, and omits `lane_order` when it equals the declaration order and `hidden_lanes` when empty. The editor's lane list shows every declared value with a visibility toggle and move up/down buttons; changing the group-by field resets both overrides (they belong to the previous field's values). Hiding every lane blocks save (`At least one lane must stay visible`).

## Fetch model

**One `list()` call per lane — a lane is a thin wrapper over that call.** Each lane issues `list({ filters, sort, items })` with:

- `filters = mergeLaneFilters(config.filters ?? {}, lane.filter)` — the base filter narrows the board as a whole; on an exact filter-key collision the lane wins. Same field with different operators AND together.
- `sort = config.sort ?? ['-updated_at']` — the view-level sort applies to every lane; there is no per-lane sort.
- `items = config.page_size ?? 25`.

Lane requests run in parallel and each lane owns its loading/error state independently — one denied or failing lane does not blank the board. The count badge reads the response's capped `meta.count` ("at least N"). A lane renders even when its query returns zero documents (lanes come from config, not from data). No "Other" lane exists: the filter grammar cannot express set negation, so "everything else" cannot be queried.

**Pagination**: a "Show more" action renders while the lane's last page came back full (`items.length === cap` — the table's next-page rule); clicking bumps that lane's cap by one page and re-fetches only that lane. The count badge keeps showing the capped `meta.count`.

## Card rendering

`KanbanCard` follows the chat `DocumentCard` shell, minus the per-card fetch — the document already arrived with the lane query:

- **Identity head** — doctype icon, `meta.display_name`, relative updated time. The head is the click target and fires `onCardClick(docId)`; `ListView` opens the peek drawer with it.
- **Body** — `DocumentViewTemplate` with the `card` template inside a bounded container (max-height 260 px, vertical scroll, horizontal clip).
- **Template resolution** — `loadDoctypeViewByKind(driver, '<domain>.<doctype>', 'card')` once per surface mount (the 60 s TTL cache shares the fetch with the peek drawer and chat cards).
- **Fallback** — `card` kind only. When the doctype has no `card` template, the card renders the identity body alone; full-page `view`/`quickView` templates never mount in a compact card.

The card root carries `data-doc-id` and lane containers key by index, so a move resolves the drop's write target by lane position.

## Moves (drag and drop)

When the view sets `allow_move` **and** the viewer holds `update` on the doctype, cards drag between lanes (`canMove` in `Kanban.svelte` — the same affordance/re-check split as the table's inline edit; the backend `WriteEnforcer` re-checks the PATCH). The move is HTML5 drag and drop: the card root is `draggable` and carries the document id in the `text/plain` payload; the lane is the drop target and highlights while a card hovers (`kb-drag-over`). Lanes whose `laneWriteTarget` is null (multi-key or non-eq filters, unwritable fields) accept no drops; their siblings still do.

A drop writes `{ [field]: value }` for the target lane's write target through `datasource.doc(id).update(...)` — the same mutation the table's inline-edit toggle performs. The move is optimistic: the card leaves the source lane and lands at the target's tail immediately, and both lanes refetch quietly after the PATCH resolves so the canonical sort and the capped counts return from the server. A failed PATCH reverts both lanes and raises the save-failed toast. One move runs at a time; drops while a move is pending are ignored. Dropping a card back on its own lane is a no-op. In custom mode the write follows the target lane only — a card can keep matching its source lane's filter and appear in both (the documented overlap semantics).

The drag-and-drop affordance is pointer-only in this version (native HTML5 DnD, no touch support); the keyboard and touch paths to change a card's value stay the peek drawer and the table's inline edit.

## Write-target rule

`laneWriteTarget(lane, fields)` returns `{ field, value }` only when the lane filter is exactly one `field__eq` entry on a field that exists, is not `read_only`/`write_only`, and is not `data` (computed). Otherwise it returns `null`. Values-mode lanes always carry a write target; expression lanes usually do not — such a lane neither accepts drops nor blocks its cards from being dragged into a lane that does. A boolean lane's wire value (`'true'` / `'false'`) coerces to a real boolean — document validation rejects the string form on a boolean field, so a move writes through the typed update path.

## Editor

`CollectionViewKanbanForm` (embedded in the `CollectionViewEditor`) authors the config:

- Board mode toggle — **By field values** vs **Custom lanes**, with descriptions.
- **Values mode** — a group-by `Select` over `groupableFields` (writable enum or boolean fields that serve the `eq` operator — every lane filters `field__eq`, so a capability-less field would 422 each lane fetch), plus the lane list: one row per declared value with the lane's colour dot and label, move up/down buttons, and a visibility `Toggle`. Changing the group-by field resets the order and visibility. The all-hidden state blocks save.
- **Allow card moves** — a `Toggle` (both modes) that persists `allow_move`; absent keeps the board read-only. The runtime still needs the viewer's `update` permission and a per-lane write target (see [Moves](#moves)).
- Custom mode — an ordered lane editor: per lane a label input, a field select, an operator select (from the field's derived `operators`), and a value control picked by `controlKindFor` (the `between` operator renders two bound controls; a `reference` field renders the `ReferencePicker` in forced mode over the field's target doctype, with the field's declared `filter` merged into its searches — the lane stores the picker's fully qualified reference token, which the backend `field__eq` accepts next to the bare id form; a `boolean` field renders a True/False dropdown; a `money` field on the `currency` operator renders a currency picker over the `core.Currency` registry with the same static fallback the FilterBar uses); plus remove and move up/down actions. The lane filter keeps its `field__op` key once the field and operator are chosen, so the controls keep their selection while the value is still blank; `validateLanes` treats a blank value as an empty filter.
- Card sort — a field `Select` over the pickable fields plus the system timestamps, and an ascending/descending toggle that composes the `-` prefix. Omitted when unset — the surface defaults to `['-updated_at']`.
- View-level base filter — an embedded `FilterBar`, dropped against stale keys on change.

Validation: values mode requires a group-by field that serves the lanes' `eq` filter (a stored view whose field lost its `filters:` capability fails the same gate) and at least one visible lane; custom mode requires at least one lane and no `validateLanes` errors (empty label, empty/incomplete filter, duplicate label — one inline error per lane at a time, label before filter). Save is blocked while any error is present.

The backend enforces the same rules at the write door: `Document::CollectionViewGate` (see [`backend/collection-view.md`](../backend/collection-view.md) → Config validation) answers `422` for a kanban `mode` outside `values` / `custom`, a `values` `group_by` that is not a writable `enum` / `boolean` field serving `eq`, and a `custom` mode with no lane. A REST- or agent-authored view therefore cannot store a config the board cannot render.

## Quirks

- The surface shows no filter bar — filters are authored in the view config (the calendar rule).
- Trash mode never renders the kanban surface: the kanban branch sits behind the live-document listing like the calendar's.
- Custom lanes may overlap — a document can appear in more than one lane; values-mode lanes are disjoint by construction.
- `lane_order` / `hidden_lanes` apply to values mode only — the custom mode's array order and lane removal cover the same needs there, and the editor ignores the overrides in custom mode when building the config.
- `allow_move` defaults to absent (off), so views saved before the option existed keep their read-only boards until an author enables moves.
- The storybook page runs with `isolate: false`, so the permission store carries across story files — the drag-and-drop story pins both permission states itself and restores the previous manifest at the end.
- Cards never compact to fit the lane — the card root carries `flex-shrink: 0`. Its `overflow: hidden` zeroes the automatic minimum size, so a default-shrink flex child of the scrollable stack would be squeezed to the lane height instead of overflowing. The lane stack scrolls; the 260 px body cap still bounds one tall card.
- A stored `sort` array is edited as one entry (field + direction); the editor round-trips only the first entry.
- The stories' identity-fallback coverage uses a purpose-built doctype without a `card` view child — the doctype-views cache keys on the doctype id, so reusing `crm.Deal` would read another story's cached template (the `DocumentCard` stories rule).
