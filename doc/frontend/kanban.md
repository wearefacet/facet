# Kanban View

The kanban surface shows a listing as horizontal lanes of cards. It is one of the `core.CollectionView` listing surfaces (`surface === 'kanban'`), rendered by `ListView` when the active view carries a `kanban` config. Each lane groups the doctype's documents by a selector; each card renders through the doctype's `card` document-view template. The surface is read-only in this first version — no drag and drop — and the stored config carries the data a later move needs.

## Source files

- `frontend/src/lib/kanban/Kanban.svelte` — surface shell: lane resolution, per-lane fetch orchestration, card-template load, empty state.
- `frontend/src/lib/kanban/KanbanLane.svelte` — one lane: header (colour dot, label, count badge), scrollable card stack, Show more, empty/error state.
- `frontend/src/lib/kanban/KanbanCard.svelte` — one card: identity head (doctype icon, display name, updated time) and the bounded DVT body.
- `frontend/src/lib/kanban/lanes.ts` — pure lane logic: `lanesFromGroupBy` (values mode), `mergeLaneFilters`, `laneWriteTarget`, `validateLanes`.
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
  lanes?: KanbanLane[]; // custom mode; render order = array order
  filters?: Record<string, unknown>; // view-level base filter
  sort?: string[]; // ListParams.sort format
  page_size?: number; // per-lane fetch cap
}
```

- **Values mode** derives the lanes from the `group_by` field's declared values at render time. The group-by picker (`groupableFields`) offers writable `enum` and `boolean` fields. On an enum, one lane per declared value, declaration order; `label = value.label ?? humanize(key)`, `color = value.color ?? hashColor(key)`, and the lane filter is `{ "<group_by>__eq": value }`. On a boolean, the two lanes True and False (localized through the filter-bar words), `color = hashColor('true' | 'false')`, and the lane filter emits the wire strings `true` / `false` — the same form the backend text path parses. The humanize step mirrors the table: a declared label wins, and a value with no label shows the humanized key. The `field__eq` key form keeps the lane filter identical in shape to what the backend and the mock both parse, and it keeps the group-by rename-safe.
- **Custom mode** stores the explicit lane list. Custom lanes may overlap or leave gaps — a document can appear in more than one lane. That is config-owned behaviour, not an error.

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

The card root carries `data-doc-id` and lane containers key by index, so a later drag-and-drop stage can resolve moved cards without touching the markup.

## Write-target rule (drag-and-drop groundwork)

`laneWriteTarget(lane, fields)` returns `{ field, value }` only when the lane filter is exactly one `field__eq` entry on a field that exists, is not `read_only`/`write_only`, and is not `data` (computed). Otherwise it returns `null`. Values-mode lanes always carry a write target; expression lanes usually do not. A boolean lane's wire value (`'true'` / `'false'`) coerces to a real boolean — document validation rejects the string form on a boolean field, and a future move writes through the typed update path. A future move is a plain `datasource.doc(id).update({ [field]: value })` — the same mutation the table's inline-edit toggle performs. Movability is derived (write target + viewer `update` permission), so no config flag or migration is needed when drag and drop lands.

## Editor

`CollectionViewKanbanForm` (embedded in the `CollectionViewEditor`) authors the config:

- Board mode toggle — **By field values** vs **Custom lanes**, with descriptions.
- **Values mode** — a group-by `Select` over `groupableFields` (writable enum or boolean fields that serve the `eq` operator — every lane filters `field__eq`, so a capability-less field would 422 each lane fetch).
- Custom mode — an ordered lane editor: per lane a label input, a field select, an operator select (from the field's derived `operators`), and a value control picked by `controlKindFor` (the `between` operator renders two bound controls; a `reference` field renders the `ReferencePicker` in forced mode over the field's target doctype, with the field's declared `filter` merged into its searches — the lane stores the picker's fully qualified reference token, which the backend `field__eq` accepts next to the bare id form; a `boolean` field renders a True/False dropdown; a `money` field on the `currency` operator renders a currency picker over the `core.Currency` registry with the same static fallback the FilterBar uses); plus remove and move up/down actions. The lane filter keeps its `field__op` key once the field and operator are chosen, so the controls keep their selection while the value is still blank; `validateLanes` treats a blank value as an empty filter.
- Card sort — a field `Select` over the pickable fields plus the system timestamps, and an ascending/descending toggle that composes the `-` prefix. Omitted when unset — the surface defaults to `['-updated_at']`.
- View-level base filter — an embedded `FilterBar`, dropped against stale keys on change.

Validation: values mode requires a group-by field that serves the lanes' `eq` filter (a stored view whose field lost its `filters:` capability fails the same gate); custom mode requires at least one lane and no `validateLanes` errors (empty label, empty/incomplete filter, duplicate label — one inline error per lane at a time, label before filter). Save is blocked while any error is present.

## Quirks

- The surface shows no filter bar — filters are authored in the view config (the calendar rule).
- Trash mode never renders the kanban surface: the kanban branch sits behind the live-document listing like the calendar's.
- Custom lanes may overlap — a document can appear in more than one lane; values-mode lanes are disjoint by construction.
- A stored `sort` array is edited as one entry (field + direction); the editor round-trips only the first entry.
- The stories' identity-fallback coverage uses a purpose-built doctype without a `card` view child — the doctype-views cache keys on the doctype id, so reusing `crm.Deal` would read another story's cached template (the `DocumentCard` stories rule).
