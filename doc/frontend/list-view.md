# Listing surface (ListView)

The listing surface shows the documents of one doctype as a table. It is the
page at `/{domain}/{doctype}`. `ListView` owns the saved-view tab strip and
picks the surface (table, calendar, kanban). `Table` owns the rows, the
manual sort, the manual filters, and the pagination. The filter bar itself is
a separate component — see [`filter-bar.md`](filter-bar.md).

## Source files

| File | Role |
| ---- | ---- |
| `frontend/src/routes/[domain=notApi]/[doctype]/+page.svelte` | The page. Parses the `filters[...]` URL params, renders the head, hosts `ListView`. |
| `frontend/src/lib/components/primitives/data/ListView.svelte` | The listing host. Fetches the `core.CollectionView` children, renders the tabs, dispatches to the surface. |
| `frontend/src/lib/table/Table.svelte` | The table surface. Rows, sort, filters, pagination, inline boolean edit, header drag-reorder. |
| `frontend/src/lib/table/TableToolbar.svelte` | Toolbar wrapper that renders the `FilterBar`. |
| `frontend/src/lib/table/types.ts` | `Column`, `SortState`, `ToolbarActionsArgs`, `TableProps`. |
| `frontend/src/lib/collectionView/viewState.ts` | The persisted manual state (localStorage). Vitest-tested. |

## Views and tabs

`ListView` reads the `core.CollectionView` children of the parent
`core.DocType` through the 60-second TTL cache. Each child is one tab. With
no children, the strip is not rendered at all — the listing shows the
**starter screen** (`CollectionViewStarter.svelte`): one card per surface
(table, kanban, calendar), each opening the view editor with that surface
preselected. A view created from the starter defaults to **personal**
(`owner_id` = the viewer). Without the `create` permission the starter
shows an explanatory note instead of the cards. Trash mode with zero views
also lands on the starter — create a view first, then browse tombstones
through it. The active tab rides the `?view=` URL param, so a view is
deep-linkable. Admin surfaces pass `showTabs={false}` — no tabs, no
saved-view affordances, always the fallback columns (never the starter).

The tab strip carries the saved-view affordances: pin (the
`pinnedCollectionViews` account setting), edit or save-as, delete, and
create. See [`settings.md`](settings.md) for the pin store.

## Column reorder

Two doors set the column order of a saved view:

- **View editor.** The edit dialog's column list moves a column with the
  arrow buttons (see `CollectionViewColumnsForm`).
- **Table header.** On a saved view, a header drags onto another header and
  the drop applies the move. The affordance is pointer-only (HTML5 drag);
  the arrow buttons stay the keyboard path. Trash mode never reorders —
  tombstones cannot be updated.

The header drag is a `Table` capability (`columnsReorderable` +
`onColumnMove`); `ListView` owns the write: it applies the index move to the
active view's `config.columns`, PATCHes the `core.CollectionView` child, and
refreshes through the same cache-invalidate + refetch path the editor's save
uses. The affordance renders only when the viewer holds `update` on
`core.CollectionView` — a UI hint; the backend re-checks the write.

## Deep links

| URL param | Meaning |
| --------- | ------- |
| `?view=<slug>` | Open the named saved view. |
| `?filters[key__op]=value` | Seed the manual filter map. Applies only when `?view=` is absent — a saved-view link keeps its own tab. |
| `?deleted=true` | Trash mode. The table lists tombstones and appends a Restore action column. |

## Table listing

The `Table` re-fetches when the datasource identity, page, page size, sort,
or filters change. A filter or sort change resets the page to 1. The toolbar
emits `field__op` keys; the free-text search rides the bare `search` key in
the same map. The footer shows the range and, when the count is a lower
bound, an open range. The rows-per-page selector offers 10, 25, 100, 250.

## Persisted manual state

The manual state of a listing survives navigation. The user sorts a column,
adds filter chips, types a search term, or picks a rows-per-page value — the
`Table` writes that state to localStorage, and restores it when the user
comes back.

- **Storage.** `viewState.ts` holds one record per listing view:
  `{ sort, filters, rowsPerPage? }`. Reads are tolerant — a corrupt or
  wrong-shaped blob reads as absent. Writes are no-ops on the server and when
  storage is unavailable.
- **Key.** `viewStateStorageKey(parentDocId, viewId, mode)` builds
  `facet.viewState.<doctype>.<viewId>.<live|deleted>`. Each saved view and
  each trash mode carry their own record; tab-less listings (no saved
  views) use the literal `default` as the view segment. A deleted view
  leaves a stale record behind; the record is tiny and never read again.
- **Restore.** The `Table` seeds its state at mount and re-seeds when the key
  changes (a tab switch or a trash-mode toggle), and resets the page to 1.
- **Precedence.** A non-empty `filters` prop wins over the stored map — a
  shared `?filters[...]` link is explicit intent. A stored sort wins over the
  `sort` prop seed. After a toolbar edit, the user's map owns the state and
  the write-back continues.
- **Scope.** Per browser only. The saved `core.CollectionView` config stays
  the shared definition; this is presentation state.
- **Opt-out.** `ListView` accepts `persistKey`: `undefined` mints the key,
  `null` disables persistence. Stories that drive sort or filter interactions
  pass `null`, so a repeated run starts clean. `Table` takes the same prop —
  `null` by default, so no other consumer persists by accident.

## Quirks

- The table instance survives a table-to-table tab switch. The state swap
  happens through the key change, not a remount. A switch through kanban or
  calendar unmounts the table; the remount restores from storage.
- The localStorage record is written on every toolbar edit. The compacted
  map (what the datasource receives) is not stored — the raw map is, so
  seeded-empty chips keep their toolbar visibility on restore.
- `ToolbarActionsArgs` (the export affordance) reports the live sort and the
  compacted filters. A restored state flows into it unchanged.
