# Grid surface (`surface: grid`)

Status: **landed** — the fourth `core.CollectionView` listing surface, mounted by
`ListView`. The deferred slices stay listed under Phasing.

The grid is the listing as a spreadsheet: a selected cell, keyboard navigation, range
selection, copy/paste with Excel and Google Sheets, fill down, and edits that save one cell
at a time. It is **not** a spreadsheet engine. Each row is a document and each column is a
field, so every rule that holds elsewhere in Facet holds here too (schema validation, RBAC,
the mutation log, Lua hooks).

**Reconciliation rule (v1): keep it simple and close to the existing code.** The design
mocks (`Facet — Grid view (excel-like) design-project.zip`) draw the destination; this
document states what the platform actually builds first, what it reuses, and what it
defers. Every reuse is named, so an implementer never invents what exists.

## Principles

1. **Row = document, column = field.** There are no free cells, no extra rows or columns, and
   no formulas. A derived value is a `data` field (computed server-side). The grid shows it
   as read-only with an `fx` marker. We never add a client-side formula language.
2. **The server is the validator.** The client coerces input only to build a well-formed
   PATCH. The 422 answer is shown on the cell. The client never pre-rejects anything the
   server would accept.
3. **Autosave per cell, batched per row.** A multi-cell operation (paste, fill) is one PATCH
   per row, never one per cell.
4. **Failures stay on their cell.** A rejected cell keeps the user's text and shows the
   error. The rest of the grid keeps working.
5. **Reuse before build.** The grid mounts the Table's toolbar, footer, cell renderer,
   and edit pattern; it adds only what makes it a spreadsheet (selection, keyboard, copy,
   frozen columns, Σ row).

## What the grid reuses (platform inventory)

| Need | Existing code |
|---|---|
| Tab strip, view pin/edit/delete | `ListView` (tabs carry surface icons, grid included) |
| Toolbar (search, filter chips) | `TableToolbar`, mounted by `Grid` exactly as `Table` does |
| Cell display (enum chips, ref capsules, money, dates) | `FieldValue` + `cellKind.ts` |
| Optimistic single-cell write, revert + toast | `Table.toggleInlineBoolean` — generalized into `writeQueue` |
| Edit permission hint | `can(domain.doctype, 'update')`; backend `WriteEnforcer` re-checks |
| Editors per type | `MoneyInput`, `DatetimePicker`, `PeriodPicker`, `ReferencePicker`, `ColorInput`, `DurationInput`, `Select`, `Input` |
| Reference picker with the field's `filter` | Already done by kanban custom lanes |
| Live updates | `subscribeCollectionRefresh` — debounced full re-query, reconnect recovery |
| Σ row | `List::Aggregate` (`sum/avg/min/max` over `integer/duration/money`) — no backend change |
| Footer range + rows-per-page + pagination | The Table footer pattern, copied |
| Keyboard registration model | `registerRouteShortcuts` / per-surface keydown |
| View editor step | `CollectionViewEditor` + per-surface forms (`CollectionViewKanbanForm` is the template) |
| Peek drawer | `QuickViewHost` wrapping `ListView` (row click / Enter / Space) |

## Config

The grid reuses the table's `config.columns`, so switching a view between **Table** and
**Grid** keeps its columns. Grid-only settings live under `config.grid`, the same nesting
`calendar` and `kanban` use.

```yaml
surface: grid
config:
  columns:
    - { key: title,        width: "300px" }
    - { key: value,        width: "160px", summary: sum }
    - { key: probability,  width: "120px", summary: avg }
    - { key: weighted,     width: "160px", summary: sum }   # data field → read-only, fx
    - { key: won,          width: "96px",  editable: false }
  grid:
    frozen: 1                   # leading columns pinned left (after # and checkbox)
    filters: { status__ne: lost }   # view-level base filter, as on kanban
    sort: ["close_date"]        # ListParams.sort format; default ["-updated_at"]
    allow_create: true          # ghost new-row line (phase 3); absent = off
```

Dropped from the earlier draft, for simplicity: `row_height` (one density, the design's
40px) and `allow_delete` (delete stays in the peek drawer / audit, as everywhere else).

### Column semantics on the grid

| Key | Table today | Grid |
|---|---|---|
| `editable` | `true` only on booleans; absent = read-only | boolean; a writable column is editable unless `false` (no legacy grid views exist, so default-on breaks nothing — kanban's `allow_move` stays the precedent for migration-sensitive flags). `true` on a non-writable field fails the gate. |
| `summary` | — | `count` \| `sum` \| `avg` \| `min` \| `max`; the field aggregates need `integer`, `duration`, or `money` (`List::Aggregate.AGGREGATE_FIELD_TYPES`). |

`TS`: `CollectionSurface` carries `'grid'`, `CollectionViewColumn.summary` and the widened
`editable?: boolean` are in, `GridViewConfig`/`config.grid` are in (all landed with phase 1).
The table keeps its current reading (only `true` matters there).

### Gate rules (`Document::CollectionViewGate.validate_grid`, mirrored in `config.ts`)

| Rule | Code |
|---|---|
| at least one column; each `key` is a parent field or `created_at` / `updated_at` | `required` / `unknown_field` |
| `summary` ∈ the set above; a field aggregate needs an aggregate-able type | `invalid_value` / `unsupported_field` |
| `grid.frozen` is an integer in `0..columns.length` | `invalid_value` |
| `grid.filters` keys serve their operators (same check as kanban `filters`) | `unsupported_field` |
| `grid.sort` fields exist and are sortable | `unknown_field` / `unsortable_field` |
| `editable: true` on a non-writable field (`read_only`, `write_only`, `data`, non-scalar) | `unsupported_field` |

Sub-field (dotted) keys are **deferred** with the sub-field columns feature — the gate grows
its dotted rule when the picker offers them.

`/check` reports the same rules as `:view` warnings.

## Layout

```
┌ tabs ────────────────────────────────────────────────────────────────┐
│ search · + Add filter · chips                                        │
├───┬───┬─────────────────────┬──────────────────────────────────────┤
│ # │ ☐ │ frozen column(s)    │ scrolling columns …                  │
│ 1 │   │                     │                                      │
│ … │   │                     │                                      │
│ Σ │   │ COUNT 8             │ SUM USD 496,500 · AVG 41.9 …         │  ← summary row
├───┴───┴─────────────────────┴──────────────────────────────────────┤
│ 1–8 of 8 · [4 cells · Sum 95,000 · Avg 47.5]    rows/page · pages    │  ← the table footer + selection chip
└──────────────────────────────────────────────────────────────────────┘
```

- **Gutter**: row number. Click selects the row, drag extends a run of rows.
- **Checkbox column**: bulk selection, the Table's `selected`/`onSelect` props.
- **Frozen columns** use `position: sticky` over px widths; a non-px width renders at the
  default and never freezes. The rightmost sticky cell carries the frozen-edge shadow.
- **Headers** show the label in a sort button (the Table's sort state format), an `fx`
  badge on `data` columns, and `*` for required fields (with the editors phase).
- **Density**: one row height (40px), no config, no toolbar toggle.
- The toolbar has **no** undo/redo or Fill-down buttons — undo is keyboard-only (`⌘Z`),
  fill is `⌘D` + the fill handle (phase 3). The toolbar stays the Table's.
- The **filter bar** is present, as on the table, because this is a working surface.

## Selection & keyboard

| Keys | Action |
|---|---|
| arrows / Tab / Home / End | move the active cell (⇧ extends) |
| ⇧ + move, or drag | extend the range |
| gutter click | select the row (⇧-gutter extends a run) |
| ⌘C | TSV copy of the range (raw stored form — money copies `120000`, enums copy the key) |
| Enter / Space | open the peek drawer for the focus row (read-only build; editing takes over Enter in the editors phase) |
| Esc | clear the selection |
| ⌘D / fill handle / ⌫ / ⌘V / ⌘Z | phase 3 (bulk + undo) |

Accessibility: `role="grid"` with `aria-rowcount`/`aria-colcount`, `role="row"` /
`role="gridcell"` / `role="columnheader"` children only (axe runs in `error` mode), cells
carry `aria-selected`, checkboxes keep their own labels (never inside `aria-hidden`).
Editors are real inputs and listboxes when they land.

## Cell editors (phase 2)

**One `CellEditor` wrapper over the existing form inputs — not twelve bespoke editors.**
The inputs already parse and format per type (`moneyFormat`, `durationMath`, the pickers).

| Field type | Display (FieldValue, unchanged) | Editor (phase 2) |
|---|---|---|
| `string` | text | `Input` inline |
| `longtext` | first line + ¶ | floating textarea, ⌘↵ commits |
| `enum` | tinted chip, neutral label ink (AA — see the divergence note below) | filter-as-you-type listbox |
| `boolean` | ✓ / ✕ | none; Space or click flips (the Table's toggle, generalized) |
| `integer`, `duration` | right-aligned mono | numeric input, min/max hint checked before the PATCH |
| `money` | `€ 45,000.00` | `MoneyInput`; currency picker only on multi-currency |
| `date`, `datetime` | ISO mono | `DatetimePicker` (⌥↓) + live parse preview |
| `period`, `dateperiod` | `start → end` | `PeriodPicker`, two segments |
| `reference` | ref capsule | `ReferencePicker` (field `filter` merged, the kanban-lane pattern) |
| `color` | swatch + hex | `ColorInput` |
| `data` | `fx`, dimmed | not editable |
| containers | — | not pickable in v1 (below) |

**Known divergence from the design mock:** the mock's enum chips carry the value color as
the text ink. On the light theme that fails AA contrast (axe `error` mode fails the story),
so the grid's chip keeps the declared color in the tinted background + dot and renders the
label in the theme ink. The Table's identical snippet carries the same latent violation —
its fixtures have no colorful enum field, so nothing trips it. Reconcile the Table when its
fixtures grow an enum column.

## Fields that don't fit a cell (v1 scope)

| Tier | v1 |
|---|---|
| Scalars, `phone`, `url`, `reference` | editable columns (editors in phase 2) |
| `object` sub-fields (`address.city`) | **deferred** — the picker, the gate's dotted rules, the nested-partial writes, and the no-sort/no-filter header states all land together, later |
| `array`, `dictionary`, `child`, `file`, untyped `object` | not offered (`PICKER_SKIP_TYPES` already excludes them); the peek drawer owns them |
| `secret`, `write_only`, tag-hidden fields | never a column (field visibility already enforces this server-side) |

## Write path (phase 2)

- **Commit** → `datasource.doc(id).update({ [key]: value })` — the exact call the Table's
  inline boolean edit makes today. Optimistic; the cell shows a saving state. On 422 the
  cell keeps the typed text, shows the message tooltip, and **Esc** reverts. On 403 the cell
  reverts, a toast fires, and the row reads read-only for the session.
- **Multi-cell ops** (paste, fill, clear): group the diffs by row, one PATCH per row,
  concurrency cap 4 (`writeQueue`), each row resolves on its own.
- **Undo**: a session-local stack of `{rowId, before, after}` per op; undo sends the inverse
  PATCH. A cell changed remotely since is skipped and reported.
- **Dependent `data` columns** dim while a source cell saves, then refresh from the row's
  PATCH response.

### Paste (phase 3)

1. Parse the pasted TSV (the same grammar copy emits: tabs, newlines, quoted cells).
2. Coerce every target cell through the editors' parse functions; skip read-only and
   unknown columns, and report them.
3. Apply directly when every cell coerces and no new rows are needed; otherwise open the
   **Paste preview** (before → after, converted, invalid, new rows), "Skip invalid cells"
   on by default.
4. Rows past the end go into the ghost new-row line (only when `allow_create`); they are
   created once every required field has a value, never as a partial document.

### New rows (`allow_create`)

The last line is a ghost row; typing builds a local draft; the `POST` fires when every
`required` field without a default has a value; Esc on an empty draft discards it. Opt-in
per view (absent = off), the kanban `allow_move` rule, AND-ed with the viewer's `create`
grant. The design's dimmed field-default preview is dropped — defaults apply server-side
on create.

## Live updates (reconciled to the platform)

The grid subscribes through **`subscribeCollectionRefresh`** — the same debounced full
re-query every listing uses (trailing 300ms, reconnect + visibility recovery, frames are
hints not source of truth). The design's per-row re-reads, initials badges, 2-second
flashes, "keep mine / take theirs" bar, and change banner are **deferred**; they need
per-row re-read machinery the platform does not have. One grid-specific rule ships with the
editors phase instead: **the re-query never clobbers a cell being edited or in flight** —
the pending map re-applies on top of the refreshed rows, and the open editor stays open.
The conflict model is the platform's: field-level diffs, last write wins on the same cell.

## Scale (deferred — the v1 data model)

v1 uses the **Table's exact data model**: `page`/`items` offset paging, capped count
(`COUNT_CAP = 1000`), the `more` flag, and the footer's open range. Nothing in the grid's
interaction layer depends on it changing.

The design's window model (blocks of 200, ≤ 2,000 rows in memory, DOM virtualization,
keyset cursors, count estimates, aggregate timeouts/caching, `select` projection) is a
**backend-first** phase of its own, ordered after the interaction layer proves out:

1. **Keyset (seek) cursors** (`after`/`before`) + **always append `id` as the last sort
   key** — the missing tie-breaker is a real bug that affects the **table today** (rows
   with equal sort keys can duplicate or skip across offset pages); the fix is one line in
   `build_order_clause` and benefits every surface.
2. **Count estimate** (`aggregate=count&estimate=true` from `EXPLAIN`), **bounded and
   cached field aggregates** (`statement_timeout`, keyed by collection version).
3. **Client window** on top of cursors: blocks, drop/refetch, jump-to-end via the reversed
   sort, cursor-persisted scroll position.
4. **Query-wide selection** → server-side export (exists) and a future bulk-update job;
   the client never loops PATCHes over a query-sized selection.

Until then the Σ row runs one parallel `list()` call per summary column (count shares one
call) — `lib/grid/summary.ts` normalizes the aggregate response shape
(`{ data: { value }, meta: { count } }`) in one place. The selection chip (cells, SUM, AVG
per currency) is client-side over the loaded rows only.

## Permissions

- The edit affordance needs `can(doctype, 'update')` **and** a writable field visible under
  the caller's `visible_tags`. Hidden fields never render as columns (server-side masking).
- Row-scoped RBAC is enforced by the backend; the grid learns from the 403.
- `allow_create` is a view-level hint, AND-ed with the `create` grant.
- Trash mode never renders the grid; it falls back to the table, like kanban and calendar.

## Files

| File | Role | Status |
|---|---|---|
| `frontend/src/lib/grid/Grid.svelte` | surface shell: toolbar, fetch, frozen columns, selection, Σ row, footer | **landed (phase 1)** |
| `frontend/src/lib/grid/selection.svelte.ts` (+ spec) | active cell, ranges, moves | **landed** |
| `frontend/src/lib/grid/clipboard.ts` (+ spec) | TSV serialize + copy text | **landed** (parse joins phase 3) |
| `frontend/src/lib/grid/summary.ts` | per-column aggregate calls, response normalization | **landed** |
| `frontend/src/lib/grid/types.ts` | `GridColumn`, `GridProps` | **landed** |
| `frontend/src/lib/grid/Grid.stories.svelte` | 6 stories, axe `error` mode | **landed** |
| `frontend/src/lib/grid/writeQueue.ts` (+ spec) | per-row batching, concurrency cap, undo stack | **landed** |
| `frontend/src/lib/grid/coerce.ts` (+ spec) | raw text → typed value (shared by editors + paste) | **landed** (paste parse joins phase 3) |
| `frontend/src/lib/grid/editors/*.svelte` | `CellEditor` over the existing form inputs | **landed** |
| `frontend/src/lib/grid/fieldTypes.ts` | the writable + aggregate-able type sets, shared by the surface and the editor | **landed** |
| `frontend/src/lib/grid/PastePreview.svelte` | the preview dialog | phase 3 |
| `frontend/src/lib/components/primitives/data/CollectionViewGridForm.svelte` | the view editor's grid step | **landed** (stories in place; the surface picker offers `grid`) |
| `src/document/collection_view_gate.cr` → `validate_grid` | backend gate rules | **landed** |
| `doc/frontend/grid.md`, `doc/backend/collection-view.md` | docs | **landed** |
| assistant skill `collection-views.md` | the `grid` vocabulary | **landed** |

Datasource groundwork (landed with phase 1): `ListParams.field` + HTTP serialization +
MockDataSource field aggregates mirroring `List::Aggregate` (numbers; money bags per
currency; `null` for an empty set), and the `validateDraft` save gate treats `grid` like
`table` (columns required).

## Phasing

1. **Read-only grid** — ✅ landed: types, `Grid.svelte` (pagination model, sticky frozen
   columns, gutter + checkbox, `FieldValue` cells, range selection, keyboard nav, copy,
   Σ row, footer + selection chip), selection/clipboard specs, stories.
2. **Editing** — ✅ landed: per-type editors over the existing inputs, `writeQueue` (one
   PATCH per row, cap 4, undo), cell-local 422 states, boolean flip, the refresh-clobber
   rule.
3. **Bulk** — TSV paste + preview, fill down / handle, clear range, ghost new-row line.
4. **App integration** — ✅ landed: the `ListView` branch + tab icon + trash skip,
   `CollectionViewGridForm` (stories in place; the picker offers `grid`), backend
   `validate_grid`, the `id` sort tie-breaker, docs (`doc/frontend/grid.md`,
   `doc/backend/collection-view.md`).

Deferred beyond phase 4: sub-field columns, live-flash/conflict machinery, keyset cursors
+ windowing + count estimate + aggregate cost control, `select` projection, series fill,
query-wide bulk jobs.

## Open decisions

- **Bulk endpoint.** v2 sends one PATCH per row, which is fine up to a few hundred rows.
  A transactional `PATCH /Api/:domain/:doctype` (`[{id, diff}]`) would make a big paste
  atomic and one audit "cause". Decide when a real paste scale demands it.
- **Enum chip contrast in the Table.** The grid fixed it locally (neutral label ink); the
  Table's shared snippet carries the latent violation until a fixture trips it.
- **Series fill** (dates +1, numbers +n) on the fill handle: the first fill phase copies only.
