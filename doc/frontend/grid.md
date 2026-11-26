# Grid View

The grid surface shows a listing as a spreadsheet: one row per document, one column per
field, a selected cell, range selection, keyboard navigation, and per-cell editing. It is
one of the `core.CollectionView` listing surfaces (`surface === 'grid'`). Each cell renders
through the same `FieldValue` renderer the table uses, and every write follows the platform
rules — schema validation, RBAC, and the mutation log. The grid is not a spreadsheet engine:
there are no formulas, no free cells, and no rows outside the listing.

The surface ships as a component with its stories. The listing's surface picker
(`CollectionViewSurfaceStep`) keeps `grid` disabled, and `ListView` dispatches only table,
calendar, and kanban — the editor authors grid views (the editor stories create and edit
them), but no app surface mounts the grid yet.

## Source files

- `frontend/src/lib/grid/Grid.svelte` — surface shell: toolbar, fetch, sticky frozen
  columns, gutter + checkbox, cell rendering, range selection, keyboard navigation, TSV
  copy, Σ row, footer, and the per-cell editors.
- `frontend/src/lib/grid/types.ts` — `GridColumn`, `GridProps`.
- `frontend/src/lib/grid/selection.svelte.ts` — active cell, ranges, moves (pure logic).
- `frontend/src/lib/grid/clipboard.ts` — TSV serialize + parse, and the copy text (pure
  logic).
- `frontend/src/lib/grid/summary.ts` — per-column Σ aggregate calls and response
  normalization.
- `frontend/src/lib/grid/writeQueue.ts` — per-row write batching, concurrency cap, and the
  session undo stack.
- `frontend/src/lib/grid/coerce.ts` — raw text → typed value for the text editors and the
  paste path.
- `frontend/src/lib/grid/editors/` — the per-type cell editors over the existing form
  inputs (`CellEditor` shell + one editor per type).
- `frontend/src/lib/grid/fieldTypes.ts` — the field-type capability sets both the surface
  and the editor read (see below).
- `frontend/src/lib/grid/Grid.stories.svelte` — Storybook stories (component tests).
- `frontend/src/lib/components/primitives/data/CollectionViewGridForm.svelte` — the view
  editor's grid form.
- `frontend/src/lib/components/primitives/data/CollectionViewGridForm.stories.svelte` —
  Storybook stories for the form.
- `frontend/src/lib/collectionView/config.ts` — the grid branch of `buildConfig` /
  `validateDraft` (the pure config logic the editor runs before save).
- `frontend/src/lib/collectionView/types.ts` — `GridViewConfig`, `GridColumnSummary`.

## Config

```yaml
surface: grid
config:
  columns:
    - { key: title, width: "300px" }
    - { key: value, width: "160px", summary: sum }
    - { key: probability, width: "120px", summary: avg }
    - { key: won, width: "96px", editable: false }
  grid:
    frozen: 1 # leading columns pinned left (after # and checkbox)
    filters: { status__ne: lost } # view-level base filter, as on kanban
    sort: ["-value"] # ListParams.sort format; default ["-updated_at"]
    allow_create: true # ghost new-row line; absent = off
```

The grid reuses the table's `config.columns` array, so a view's columns survive a surface
change. Grid-only settings live under `config.grid`, the same nesting `calendar` and
`kanban` use.

### Column semantics

| Key        | Table                                       | Grid                                                                                                                                                                      |
| ---------- | ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `editable` | `true` only on booleans; absent = read-only | A writable column is editable unless `false`. Only the opt-out persists — the editor drops a checked flag, so a stored config never carries a redundant `editable: true`. |
| `summary`  | —                                           | `count` \| `sum` \| `avg` \| `min` \| `max`. `count` runs field-free on any column; the field aggregates need an aggregate-able type (`integer`, `duration`, `money`).    |

A writable column is a schema field whose type is in `WRITABLE_FIELD_TYPES`
(`grid/fieldTypes.ts`) and that is neither `read_only` nor `write_only`. The system
timestamps (`created_at` / `updated_at`) render but never edit. Containers, `data`, `file`,
`secret`, and `any` never edit — the peek drawer owns them.

### Field-type capabilities (`grid/fieldTypes.ts`)

`WRITABLE_FIELD_TYPES` is the set the cell editors cover; `isWritableField` adds the schema
flags. `AGGREGATE_FIELD_TYPES` mirrors the backend `List::Aggregate.AGGREGATE_FIELD_TYPES`;
`isAggregatableField` gates the Σ field aggregates. `Grid.svelte` and the view editor's
grid form both import these — the two surfaces cannot drift apart on what a cell can write
or what a Σ cell can aggregate.

## Surface

`Grid.svelte` mounts the table's toolbar pattern (search, filter chips) and the table's
footer pattern (range, rows-per-page, pagination). On top of that it adds:

- **Frozen columns** — the first `grid.frozen` data columns stick left over px widths
  (`position: sticky`); the rightmost sticky cell carries the frozen-edge shadow. A non-px
  width renders at the default width and never freezes.
- **Selection model** — `selection.svelte.ts` owns the active cell and the range. Arrows,
  Tab, Home, and End move; Shift extends; the gutter click selects a row; drag extends a
  range. Esc clears. Enter and Space open the peek drawer, except on a writable cell where
  editing takes over.
- **Copy & paste** — ⌘C serializes the range as TSV in the raw stored form (money copies
  `120000`, enums copy the key, a range cell copies its two stored bounds as
  `start → end` — a `period`'s UTC instants, a `dateperiod`'s calendar dates). A native
  paste on the focused cell reads the same grammar back — Excel's copy dialect included
  (`\r\n` row breaks, quoted multi-line cells, `TRUE`/`FALSE`, thousands-separated
  decimals like `1,234.56` / `1 234,56`). The block lands with its top-left at the
  selection's top-left and never leaves the loaded page: rows and columns past it are
  skipped, as are read-only cells (one toast counts them). A cell whose text does not
  coerce keeps its value and takes the error frame (Esc drops it, and so does a later
  paste that coerces on the same cell); each touched row sends one PATCH, so
  ⌘Z reverts one row per press. After the paste the selection covers the pasted block.
- **Σ row** — columns with a `summary` run one parallel `list({ aggregate, field })` call
  each over the whole filtered set (`summary.ts`); `count` summaries share one call. A
  failed aggregate leaves its Σ cell empty.
- **Cell editing** — Enter, F2, double-click, or a typed character opens the
  `CellEditor` for the field type (the editors wrap the existing form inputs: `MoneyInput`,
  `DatetimePicker`, `ReferencePicker`, and so on). Booleans flip in place with no edit
  mode. Writes go through `writeQueue.ts` — one PATCH per row, concurrency cap 4, with a
  session undo stack (⌘Z). A rejected cell keeps the typed text under a local error state
  (Esc reverts); a 403 reverts, raises a toast, and locks the row read-only for the
  session. A refetch re-applies in-flight cell values and leaves the open editor open.
  The `longtext`, `datetime`, and period editors float over the cell — five datetime
  segments (or two bound pickers) never fit one column — and the datetime and period
  frames show the parsed value while typing: the stored UTC form (a `period`'s
  `start → end`) the complete entry will commit; a partial edit holds the last complete
  value. A `date` cell edits in the cell box — a calendar date never converts, so the
  segments are the value.

## Editor

`CollectionViewGridForm` (embedded in the `CollectionViewEditor`) authors the config:

- **Grid settings** — a frozen-columns select (0 to the column count, `None` at 0) and a
  new-rows `Toggle` that persists `allow_create`; absent keeps the grid read-only at the
  create door. Removing a column clamps the frozen count to the remaining set.
- **Column builder** — the two-pane picker with the grid sections. The available pane
  groups the remaining fields into **Editable in grid** (writable schema fields) and
  **Read-only** (`data`, `read_only` fields, the system timestamps); `write_only` fields
  are never offered. Each selected row carries the label input, the field key, the type
  badge, the Edit checkbox (writable fields only), the Σ summary select, the Frozen marker
  (rows inside the frozen count), and the remove action. A key that no longer resolves to a
  field shows a warning note — the row stays until the author removes it.
- **Σ summary** — the select offers `count` on every column and the field aggregates only
  on an aggregate-able type. Clearing drops the key.
- **Row sort** — a field `Select` over the sortable fields plus the system timestamps, and
  an ascending/descending toggle that composes the one-entry `sort` array with the `-`
  prefix (the kanban rule). Omitted when unset — the surface defaults to `['-updated_at']`.
- **View-level base filter** — an embedded `FilterBar`.

The draft values live in the parent (`CollectionViewEditor`); each bindable prop
round-trips the writes, and the column mutations replace the array — the same pattern the
kanban form uses.

`buildConfig`'s grid branch normalizes the saved config: it drops `editable` from
non-writable columns (a stale flag the gate would reject), keeps only the `editable: false`
opt-out, drops a field aggregate whose type the backend refuses, clamps `frozen` into
`0..columns.length`, composes the sort only when the field still resolves to a sortable
def, and drops stale filter keys against the editor's filterable set. `validateDraft`
blocks save on the same at-least-one-column rule the table uses.

The form's stories assert the column semantics through the DOM; the stored-config rules
are pinned in `collectionView/config.spec.ts` (the `buildConfig — grid` block), and the
editor stories read the saved payload back from the driver (`CreateGrid`, `EditGridSave`).

## Gate status

The backend `Document::CollectionViewGate` validates `table`, `calendar`, and `kanban`
configs (see [`backend/collection-view.md`](../backend/collection-view.md) → Config
validation). A `grid` surface passes the backend gate unvalidated today; the frontend
`buildConfig` normalization is the write path's only guard.

## Quirks

- The surface has a filter bar (the table rule) — the grid is a working surface, not a
  read-only projection.
- One row height (40 px); no density config.
- The toolbar has no undo or fill buttons — undo is keyboard-only (⌘Z), and fill is the
  fill handle in a later phase.
- Fill down and the ghost new-row line are later phases; `allow_create` is authored
  already and stays off unless the view opts in.
- Paste reads the ISO grammar and the copy forms — the stored raw values, ` → ` ranges,
  and locale-shaped decimals. Excel's localized date text (`30/09/2026`) needs a reformat
  before it lands.
- The enum chip carries the value colour in the tinted background and dot, and the label in
  the theme ink — the design mock's value-coloured text fails AA contrast on the light
  theme.
- The grid owns the focus indicator: a pointer press focuses the pressed cell (never an
  inner control), a keyboard move carries the DOM focus to the new focus cell, and the
  cells paint no user-agent outline — the focused cell's ring is the one highlight. The
  UA outline would only paint while the window is focused, so it read as a stray
  highlight that vanished on screenshots.
- The stories seed explicit column sets, not `defaultColumns` — the fixture loader sorts
  the schema fields alphabetically, so the seeded set shifts with the fixture.
