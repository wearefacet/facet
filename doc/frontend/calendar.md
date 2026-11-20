# Calendar View

The calendar surface places documents on a month or week grid by a date/time discriminator field. It is one of the `core.CollectionView` listing surfaces (`surface === 'calendar'`), rendered by `ListView` when the active view is configured with a `calendar` config.

## Source files

- `frontend/src/lib/calendar/Calendar.svelte` — surface shell: header, toolbar, navigation, data fetch, month/week switch.
- `frontend/src/lib/calendar/MonthGrid.svelte` — month grid with all-day chips and range bars.
- `frontend/src/lib/calendar/WeekGrid.svelte` — week grid with an all-day gutter and an hour-grid for time-anchored chips.
- `frontend/src/lib/calendar/discriminator.ts` — pure logic: discriminator kind resolution, interval resolution, window-filter construction, overlap predicate, grid geometry, chip placement.
- `frontend/src/lib/calendar/discriminator.spec.ts` — Vitest `server` project tests for the pure logic.
- `frontend/src/lib/datasource/maintenanceTaskSeed.ts` — re-anchors the MaintenanceTask fixture dates relative to today.
- `frontend/src/lib/components/primitives/navigation/FilterBar.svelte` — the reusable filter bar embedded in the calendar view configuration (see [`filter-bar.md`](filter-bar.md)).

## Public API

### Discriminator kinds

`calendarDiscriminatorKind(fieldType, endField)` maps a discriminator field to a kind:

| Field type | `end_field` set | Kind |
| ---------- | --------------- | ---- |
| `date`     | no              | `date` |
| `date`     | yes             | `date-range` |
| `datetime` | no              | `datetime` |
| `datetime` | yes             | `datetime-range` |
| `dateperiod` | (ignored)     | `date-range` |
| `period`   | (ignored)       | `datetime-range` |
| other      | —               | `null` (surface hidden) |

### Fetch window

`calendarFetchWindow(year, month, weekStart)` computes the fetch bounds for a month grid, in UTC epoch ms:

- `gridStart` — epoch ms (UTC midnight) of the first rendered grid cell (the first day of the week containing day 1 of `month`).
- `fetchFrom` — the fetch lower bound, `gridStart` minus one day.
- `fetchTo` — the fetch upper bound, `gridStart` plus 42 days.

The fetch lower bound is one day before the grid start because dates are always stored in GMT and the server does not know the client's timezone: a document whose GMT date falls on the boundary day must still be fetched. For example, August 2026 with `week_start: 'monday'` renders from Monday July 27, so the fetch starts Sunday July 26.

### Window filter

`buildCalendarWindowFilter(config, kind, fromIso, toIso, extraFilters?)` builds the `list()` filter covering the visible window. The `fromIso` bound is the fetch lower bound (`fetchFrom`), not the grid start.

- Scalar `date` / `datetime` discriminators filter by `__gte` / `__lte` on the discriminator (and `end_field` when set).
- Native range fields (`period` / `dateperiod`) store `{start, end}` as a single object, so scalar comparison filters cannot match them. The production backend queries them with a GiST `__overlaps` range operator; the `MockDataSource` does not support it. For these, the filter emits **no window filter** — the caller fetches a wide window and narrows client-side with `overlapsVisibleWindow`.
- The `extraFilters` argument (the view's persisted `config.filters`) is merged into the returned filter map, so user-authored filters apply on top of the window bound.

### Persisted filters

`CalendarViewConfig.filters` holds the active filter map (`field__op` → value), authored in the `CollectionViewEditor` via the reusable `FilterBar` and saved with the view. The calendar applies it to every `list()` fetch by passing it as `extraFilters` to `buildCalendarWindowFilter`. Filters are never shown on the calendar surface — they are configured in the view's config popup.

### Overlap predicate

`overlapsVisibleWindow(interval, fromDay, toDay, fromInstant, toInstant)` returns true iff a resolved interval intersects the visible window. Used for native range fields in the mock path.

### Chip title

`renderCalendarTitle(data, template, fallbackFields, displayName?)` resolves the label a chip shows:

1. A set `title_template` renders through the Jinja-subset renderer (`{{ field }}` — see [`templating.md`](templating.md)); an empty render falls through.
2. The document's stored `display_name` (`meta.display_name`) — the same label the kanban card shows.
3. The first non-empty string value among the doctype's flat string fields (`titleFallbackFields`) — the safety net for doctypes with no display_name template.

The grids then fall back to the document id, and to `—` when even the id is absent.

### Label fallback

`humanizeLabel(key)` humanizes a field key as a fallback display label when the field has no explicit `title` in its definition: it splits on `_` / `-`, capitalizes the first word, and lower-cases the rest (`scheduled_window` → `Scheduled window`). The toolbar never prints the raw discriminator field key — it always shows the field's `title` (humanized fallback otherwise). The `Colour by` chip was removed from the toolbar; the color legend is now prefixed by the color-by field label (e.g. `Status:`).

### Density grouping (month view)

When a single-day cell or a week row's multi-day range bars would overflow the cell budget, the month grid collapses the chips/bars into a single `X documents` group indicator:

- `GROUP_CHIP_THRESHOLD` is the minimum hidden-chip count before a single-day cell collapses to one group chip.
- `shouldCollapseCell(totalChips, visibleSlots)` decides the collapse for a single-day cell.
- `shouldCollapseRowBars(reservedLanes, maxLanes)` decides the collapse for a week row's multi-day bars (a range that crosses a week boundary already becomes one bar per week row, so grouping is per row).

Clicking either group opens the same popover that lists every document behind it; each row in the popover opens the document quickview via `onChipClick`.

### Month cell lane layout

Range bars live in an absolutely-positioned lane block at the top of each week row; single-day chips stack below it inside each day cell. The month grid offsets chips downward by `effectiveReservedLanes × (LANE_HEIGHT + 2)` so they never collide with the bars above. `effectiveReservedLanes` is the row's `reservedLanes`, or `1` when the row's bars are collapsed into one group bar. The collapsed group bar spans only the union of its underlying bars' day columns (not the full week), so empty trailing days stay clear of single-day chips on other days.

### Fixture date shifting

`shiftMaintenanceTaskDates(docs)` re-anchors the static `data/fixtures/ops.MaintenanceTask/documents.yml` documents so their dates are relative to today, preserving each task's day offset from the anchor (a single global shift keeps relative gaps and multi-day spans intact). The static file is left untouched — backend tests rely on it — and only the in-memory copy the frontend seeds is shifted. `seedMockData` applies the shift to the `ops.MaintenanceTask` fixture before seeding.

## Quirks

- The calendar defaults its anchor to today. The MaintenanceTask fixture documents are shifted relative to today at seed time so the storybook shows a populated grid whenever it runs.
- The fetch range starts one day before the first rendered grid cell (see `calendarFetchWindow`): dates are stored in GMT, and the server does not know the client timezone, so boundary-day documents must be fetched.
- Native range fields (`period` / `dateperiod`) cannot be filtered by scalar `__gte` / `__lte` in the mock; they are fetched wide and overlapped client-side. The production backend uses the GiST `__overlaps` operator instead.
- `compareDay` orders `{y, m, d}` tuples field by field. It is not a day-distance function: across a month boundary it returns a month-number difference (Sep 6 vs Aug 31 → `1`). Use `diffUtcDays` (epoch-day difference) for column indexes and span sizes; keep `compareDay` for ordering and equality checks.
- Week view places `date`-kind chips in the all-day gutter by `startDay` (they carry no time anchor, so `resolvedChips` keeps them even though `start` is null). `clusterWeekChips` positions only `datetime` kinds on the hour grid, so a chip renders in exactly one place.