# PeriodPicker — range-field entry (`period` / `dateperiod`)

`PeriodPicker` is the primitive that gives the two range field types a working form entry: a Start/End pair of segment editors inside one frame, with one label over the pair and one shared Clear. Its contract mirrors the backend's range rules — **the bound value commits as the complete `{start, end}` object or as `''`; a half-set range is never written** — and each mode matches one backend type:

- `mode: 'datetime'` — a `period` field. Each bound edits through the timezone-aware `DatetimePicker`: wall-clock entry in the user's `core.timezone`, committed bounds in UTC `...Z`. Bounds are `[)` — start must be strictly before end.
- `mode: 'date'` — a `dateperiod` field. Each bound is a date-granularity `DatetimePicker`: calendar dates commit verbatim as `YYYY-MM-DD` and never convert through a timezone. Bounds are `[]` — inclusive both ends, start may equal end.

Consumers: the Document View Template's `input-period` / `input-dateperiod` nodes (`DvtInputPeriod`, `DvtInputDateperiod`) and `DocumentForm`'s fallback form for the two range types.

## Source files

| File | Purpose |
|---|---|
| `frontend/src/lib/components/primitives/forms/PeriodPicker.svelte` | The component — bound pair, commit rule, order hint, shared Clear |
| `frontend/src/lib/components/primitives/forms/PeriodPicker.stories.svelte` | Storybook stories; play functions are the component tests |
| `frontend/src/lib/components/features/document-view/DvtInputPeriod.svelte` | The `input-period` node (mode `datetime`) |
| `frontend/src/lib/components/features/document-view/DvtInputDateperiod.svelte` | The `input-dateperiod` node (mode `date`) |

## Public API

| Prop | Type | Default | Purpose |
|---|---|---|---|
| `value` | `'' \| { start: string; end: string }` (`$bindable`) | `''` | The bound range; `''` = "not set". The value type is `PeriodValue` (`$lib/doctype/types.ts`) — the same shape the backend's `RangeType` validates |
| `mode` | `'datetime' \| 'date'` | `'datetime'` | `datetime` for `period` fields (UTC bounds), `date` for `dateperiod` fields (calendar-date bounds) |
| `timezone` | `string` | `displayTimezone()` | IANA zone for wall-clock entry of the timestamp bounds. Ignored in `date` mode — calendar dates never convert |
| `label` | `string` | — | Field label; one label over the pair. Also seeds the group's `aria-label` |
| `required` | `boolean` | `false` | Asterisk on the label |
| `helper` / `error` | `string` | — | Hint and error text; error adds `role="alert"` and the danger border |
| `disabled` | `boolean` | `false` | Locks both bounds and the Clear action |
| `onchange` | `(v: PeriodValue) => void` | — | Fired on every commit with the new pair or `''` |

## Behavior

- **Layout:** one field box holds the Start bound, a muted `→` separator, and the End bound. Each bound renders a compact `DatetimePicker` (bare segment field + calendar popover) under a small uppercase sub-label. The footer prints the committed pair (`start → end`, mono) or `not set`; the Clear action resets both bounds.
- **Commit rule (the range-level contract of `DatetimePicker`):** the bound value commits as `{start, end}` only when both bounds are complete, and as `''` when both are cleared. A partial edit (one bound set, one empty) is not a representable range — the last committed value holds until the edit completes either way, so a half-typed edit never wipes a set range. On save the form sends either the complete pair or nothing; `formDiff` passes the object through untouched and coerces `''` to `null` (clear).
- **Order hint:** a client-side check mirrors the backend's bound rule and renders the backend's message family on the End control — `Start must be strictly before end (bounds are '[)' — exclusive upper)` for `datetime`, `Start must be on or before end (bounds are '[]' — inclusive both ends)` for `date`. The check compares the parsed bounds (mixed precision safe). The backend stays the source of truth: a 422 still surfaces through the shared `error`, and the inverted pair still commits so the save attempt carries the user's real input.
- **Per-bound errors attribute to the field.** The backend reports bound violations at `field.start` / `field.end`; the error map groups them under the top-level segment, so both render on the one control's shared error line.
- **Clear** is disabled while both bound editors are empty.

## Usage

```svelte
<PeriodPicker
	label="Scheduled window"
	mode="datetime"
	bind:value={doc.data.scheduled_window}
/>
```

`mode: 'date'` for a `dateperiod` field — `Europe/Warsaw` typing wall-clock bounds commits UTC `...Z` bounds in `datetime` mode; in `date` mode the typed calendar dates are stored verbatim.

## DVT nodes

Three form nodes bind the range and date field types (see `doc/frontend/workflow.md` → Form input nodes):

| Node | Field type | Control | Committed value |
|---|---|---|---|
| `input-period` | `period` | `PeriodPicker mode="datetime"` | `{start, end}` — UTC `...Z` bounds |
| `input-dateperiod` | `dateperiod` | `PeriodPicker mode="date"` | `{start, end}` — `YYYY-MM-DD` bounds |
| `input-date` | `date` | `DatetimePicker granularity="date"` | `YYYY-MM-DD` string |

All three follow the shared input-node contract: required `field` + `label`, optional `required` / `helper`, and read-only rendering through `DvtValue` when no `values` bag is present. The authoring validator (`Doctype::ViewTemplateValidator`) pins each node to its field type — `input-datetime` on a `date` field is an affinity warning, because the datetime picker commits a full timestamp the backend's `DateType` rejects.

## Testing

The stories run as tests in the `storybook` project (`@storybook/addon-vitest`): both modes' prepopulated rendering, the pair-commit on typing, the hold rule on a partial edit, both order hints (inverted bounds still commit), equal `dateperiod` bounds allowed, shared Clear, disabled state, and the read-only path of the `DvtInput*` nodes. The stories carry the audit-22 a11y backlog override (`test: 'todo'`) inherited from the embedded `DatetimePicker` surface.
