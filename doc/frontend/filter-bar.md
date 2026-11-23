# Filter Bar

The filter bar is a reusable, schema-aware filter surface shared by listing surfaces. It reads a doctype's `operators` metadata to render a free-text search box, a "+ Add filter" menu, and one chip per active filter (each chip carries an operator dropdown plus a value control matched to the field type and operator). It emits the same `field__op=value` filter keys the backend `ListRequest` and the `MockDataSource` both understand.

## Source files

- `frontend/src/lib/components/primitives/navigation/FilterBar.svelte` — the reusable filter bar (search + add-filter menu + per-filter chips).
- `frontend/src/lib/components/primitives/navigation/FilterBar.stories.svelte` — Storybook stories (component tests) for empty and pre-seeded states.
- `frontend/src/lib/components/primitives/navigation/FilterMultiSelect.svelte` — the chip value control for `in`: a compact Bits-UI multi-select over a field's enum options, capped at `MAX_IN_VALUES`.
- `frontend/src/lib/doctype/filters.ts` — pure helpers: operator selection, filterable-field discovery, filter-key building, control-kind resolution, system-timestamp field defs.
- `frontend/src/lib/doctype/currencies.ts` — the currency picker's option source (`core.Currency` registry through the driver, static fallback) for the `currency` operator.
- `frontend/src/lib/table/TableToolbar.svelte` — thin wrapper that renders the `FilterBar` for the table surface.
- `frontend/src/lib/components/primitives/data/CollectionViewEditor.svelte` — embeds the `FilterBar` so calendar-view filters are authored and persisted.

## Public API

### `FilterBar` component

| Prop                   | Type                       | Description                                                                                                                                                                                                         |
| ---------------------- | -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `doctype`              | `DoctypeDef` (optional)    | Parsed doctype definition. When undefined, nothing renders.                                                                                                                                                         |
| `filters`              | `Record<string, unknown>`  | Active filters, keyed by `field__op`. Controlled by the parent.                                                                                                                                                     |
| `driver`               | `DataDriver` (optional)    | Driver used to resolve `reference` filter comboboxes. When absent, references are offered as free text.                                                                                                             |
| `onFilterChange`       | `(filters) => void`        | Called with the new filter map on every change.                                                                                                                                                                     |
| `showSearch`           | `boolean` (default `true`) | Whether to render the free-text search box.                                                                                                                                                                         |
| `showSystemTimestamps` | `boolean` (default `true`) | Whether to offer the synthesized `created_at` / `updated_at` filters. Document listings answer them through a dedicated WHERE branch; a surface whose backend drops those keys (e.g. the audit log) passes `false`. |

The `FilterBar` is **controlled**: the parent owns the `filters` map and reflects it back through `onFilterChange`. It renders nothing when `doctype` is undefined.

### Filter helpers (`doctype/filters.ts`)

| Function                      | Purpose                                                                                                                       |
| ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------- | --------------- |
| `operatorsFor(field)`         | Operators a field supports, restricted to those the bar can render.                                                           |
| `filterableFields(fields)`    | Fields with at least one renderable operator, excluding system-hidden.                                                        |
| `filterKey(field, op)`        | Builds the `field_name                                                                                                        | op` filter key. |
| `controlKindFor(field, op)`   | Coarse control kind (`enum`, `enum-multi`, `reference`, `boolean`, `number`, `datetime`, `text`).                            |
| `operatorLabel(op, field)`    | Human-facing operator label, refined by field type.                                                                           |
| `SYSTEM_TIMESTAMP_FIELD_DEFS` | Virtual `created_at` / `updated_at` field defs. The add-filter menu and the CollectionViewEditor column picker both use them. |
| `parentFieldDef(doctype)`     | Virtual `parent_id` field def for owned-child doctypes (`member_of` set) — `undefined` otherwise. The bar merges it into its field list so the add-filter menu offers the parent. |

## Usage

### In the table

`TableToolbar` renders the `FilterBar` directly. The `Table` owns the filter state and passes it through:

```svelte
<FilterBar {doctype} {driver} filters={activeFilters} onFilterChange={handleFilterChange} />
```

The `Table` persists the filter map per listing view in localStorage — the chips and the search term survive a return visit. See [`list-view.md`](list-view.md) → Persisted manual state.

### In the calendar view configuration

The calendar never shows the filter bar on the surface. Instead, the `CollectionViewEditor` embeds the `FilterBar` in its calendar-surface config step. The authored filter map is saved into `CalendarViewConfig.filters`; the calendar applies it to every `list()` fetch.

## Filter keys

The bar emits `field__op` filter keys (e.g. `status__eq`, `status__ne`, `probability__gt`, `value__gte`, `value__between`, `status__in`, `value__currency`). The backend `ListRequest` parses the trailing operator suffix; values are sent as-is, with `between` values serialized as `[start, end]` arrays and `in` values as JSON arrays of the picked keys. The operator vocabulary is `eq`, `ne`, `gt`, `gte`, `lt`, `lte`, `between`, `in`, `match`, and `currency`, in the backend `Operator` declaration order — a field offers an operator only when its derived `operators` metadata includes it, so the bar never emits a filter the doctype cannot answer. The remaining backend operators stay out until the bar grows a value control for them: `starts_with` (text) is a trivial addition, and `contains` / `overlaps` / `within` need range or array editors. `ne` shares `eq`'s value control (an exclusion filter takes the same value shape as equality) and renders as `≠` ("is not" on enum/reference/boolean fields); `gt`/`lt` render as `>` / `<` and reuse the same type-driven scalar controls as `gte`/`lte`; `in` renders as "is any of" over `FilterMultiSelect`, the chip multi-select (the backend derives `In` for enum fields). A boolean field offers only `is` / `is not` — the backend serves just `eq` / `ne` on a boolean field that declares `equality` (no ordering, no substring match) and derives no other operators for it — and renders a True/False dropdown that emits the string `true` / `false`, the same wire form the backend has always parsed. A `money` field that declares the `currency` capability additionally gets the `currency` operator: the chip renders a currency picker over the `core.Currency` registry (active rows, favorites first — loaded lazily through the driver, with a static ISO-4217 fallback when no driver can be reached) and emits the stored ticker (`value__currency=EUR`), the form the backend money clause compares against the field's stored `currency` member. The amount operators (`eq`/`gt`/…) on a money field stay a bare number input: a bare amount compares numerically across currencies, and a `"<CCY> <amount>"` string adds a currency predicate for callers that need it.

The `in` chip respects the backend `Util::FilterSet::MAX_IN_VALUES` bound (mirrored as `MAX_IN_VALUES` in `doctype/filters.ts`): a `__in` array that is empty, non-array, or over the cap degrades to an always-false clause, so the multi-select disables unchecked items at the limit instead of letting users build a filter that silently matches nothing. A freshly added `in` chip seeds an empty array — it filters nothing until the user picks, the same seeded-empty contract a `between` chip has with its blank bounds. System timestamps (`created_at`, `updated_at`) are offered as datetime filters rendered by the timezone-aware `DatetimePicker` (compact mode): the user enters wall time in their `core.timezone` zone and the committed value is UTC RFC-3339 (see [`datetime-picker.md`](datetime-picker.md)).

An owned-child doctype (one declaring `member_of`) additionally gets a synthesized `parent_id` reference filter — owned children define no back-reference field, so `parentFieldDef` exposes the parent (e.g. filter spare parts by machine) as an `eq`-only filter rendered by the standard reference combobox over the parent doctype. The emitted key is `parent_id__eq` and the value is the parent's fully qualified id (`domain.Parent.id`), which the backend strips to the bare stored id (`meta.parent_id`). Doctypes that are not owned children never see the entry.

Reference option labels resolve in three steps: the backend-computed `display_name` from the row meta first, then the target doctype's first `string` / `longtext` field, then the raw id. The definition lookup falls back to the 60s-TTL `DoctypeRegistry` snapshot for drivers that keep no local definition store (the HTTP driver) — without it every label would degrade to the id. Re-resolving a chip label after a reload strips the anchored `domain.{target}.` prefix before the `id__eq` lookup: the backend `id` system filter compares bare stored ids, so a qualified token would miss.

## Quirks

- Filters are **not** applied when `doctype` is absent — the bar renders nothing.
- The filter bar never mutates its `filters` prop; it always calls `onFilterChange` with a fresh object.
- `between` value shapes differ by operator, so changing a chip's operator resets its value (a `between` range and a scalar equality are incompatible shapes).
