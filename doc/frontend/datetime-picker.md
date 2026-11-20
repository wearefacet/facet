# DatetimePicker — timezone-aware datetime entry

`DatetimePicker` is the primitive that replaces the browser's native `datetime-local` input: a segmented `YYYY-MM-DD HH:MM` editor with an attached calendar popover (month grid + quick time slots), mono type, keyboard-first, styled to the design tokens. Its contract matches the backend's time rules — **the bound value is always UTC RFC-3339; the user enters wall-clock time in their own timezone.**

A `granularity: 'date'` mode adapts the same machinery to calendar-date fields (`date`-typed): the time segments, the quick time slots, and the footer readout disappear, and the committed value is a `YYYY-MM-DD` string — a calendar date is not an instant, so it renders verbatim and never converts through a timezone.

Consumers: the `FilterBar` datetime chips (compact mode), the audit table's From/To bounds, the API-key expiry in `NewApiKeyDialog`, `DocumentForm`'s fallback form for `datetime` and `date` fields, the Document View Template's `input-datetime` node (`DvtInputDatetime`) and `input-date` node (`DvtInputDate`), and both bounds of `PeriodPicker`.

## Source files

| File                                                                         | Purpose                                                                                              |
| ---------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- |
| `frontend/src/lib/components/primitives/forms/DatetimePicker.svelte`         | The component — segmented editor, Now/Clear actions, footer readout                                  |
| `frontend/src/lib/components/primitives/forms/DatetimePicker.stories.svelte` | Storybook stories; play functions are the component tests                                            |
| `frontend/src/lib/zonedTime.ts`                                              | Pure conversion layer — UTC ISO-8601 ↔ wall-clock parts, per IANA zone; `Intl` only, no dependencies |
| `frontend/src/lib/zonedTime.spec.ts`                                         | Vitest unit spec for the conversion math (server project)                                            |

## Public API

| Prop               | Type                    | Default             | Purpose                                                                                                                                                                                                                                     |
| ------------------ | ----------------------- | ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `value`            | `string` (`$bindable`)  | `''`                | `granularity: 'datetime'` — a UTC RFC-3339 timestamp (`...Z`); `granularity: 'date'` — a `YYYY-MM-DD` calendar date. `''` = "not set"                                                                                                       |
| `timezone`         | `string`                | `displayTimezone()` | IANA zone used for wall-clock entry. Falls back to the settings store's `displayTimezone()` — the `core.timezone` setting, with the `auto` sentinel or a not-yet-loaded store resolving to the browser zone (see `settings.md`)             |
| `label`            | `string`                | —                   | Field label; also seeds element ids for `for`/`aria-describedby`                                                                                                                                                                            |
| `required`         | `boolean`               | `false`             | Asterisk on the label                                                                                                                                                                                                                       |
| `helper` / `error` | `string`                | —                   | Hint and error text; error adds `role="alert"` and the danger border                                                                                                                                                                        |
| `disabled`         | `boolean`               | `false`             | Locks segments and actions                                                                                                                                                                                                                  |
| `granularity`      | `'datetime' \| 'date'`  | `'datetime'`        | `'date'` hides the `HH:MM` segments, the quick time slots, and the footer time readout: the user edits a calendar date, the committed value is `YYYY-MM-DD` verbatim (never timezone-converted), and the calendar panel commits on day pick |
| `onchange`         | `(iso: string) => void` | —                   | Fired on every commit with the new UTC ISO string (or the `YYYY-MM-DD` date in date granularity)                                                                                                                                            |

## Behavior

- **Segments:** `YYYY` `–` `MM` `–` `DD` `&nbsp;` `HH` `:` `MM` — digits only, per-segment maxlength. A completed segment auto-advances focus; focus selects all.
- **Clamping:** a finished segment is clamped to its valid range (month 1–12, day 1–`daysInMonth`, hour 0–23, minute 0–59). Changing month/year re-normalizes the day (Jan 31 → Feb 28). Impossible dates cannot be committed.
- **Keyboard:** `ArrowUp`/`ArrowDown` bumps the focused segment (hours and minutes wrap; month, day, and year clamp). `ArrowLeft`/`ArrowRight` move between segments.
- **Commit rule:** value commits only when the visible segments form a real calendar datetime. A partial edit never wipes a set value: while any segment is incomplete, or the time is half-entered (hour without minute, or the reverse), nothing emits and the last committed value holds. Only the explicit `Clear` emits `''`. In `granularity: 'datetime'`, a complete date with an untouched time commits midnight (`00:00`) — the calendar day-pick precedent. Every commit emits UTC, converted from wall time in the active zone. In `granularity: 'date'` the commit is the literal `YYYY-MM-DD` of the three date segments (a stored date is parsed back directly, never through the zone) — it commits when the third segment completes, and an impossible date (Feb 30) still cannot be committed.
- **Calendar panel:** a calendar icon button in the field toggles an attached popover: a Monday-first month grid (‹/› month navigation, `aria-live` month title, today dot, selected-day gold fill, muted adjacent-month days) and, in `granularity: 'datetime'`, a row of quick time-slot chips (`00:00 06:00 12:00 16:00`). Picking a day keeps the current time and commits; picking a slot sets hour/minute on the displayed (or current) date and commits. In `granularity: 'date'` the day pick is the whole commit. Month navigation alone never commits. The panel closes on outside pointer-down or `Escape` (which refocuses the year segment); opening it recenters the view on the selected value or today.
- **Now / Clear:** `Now` writes the current instant — in `granularity: 'date'`, today's calendar date in the display zone. `Clear` resets to `''`. Clear is disabled while there is nothing to clear.
- **Footer:** local wall time plus the zone offset label in effect at the displayed instant (e.g. `(GMT+5:30)`), and the raw UTC value. With no value set, the label falls back to the zone's current offset. The footer is hidden in `granularity: 'date'` — the segments already show the whole committed value. A complete date with an untouched time renders its committed midnight, though its time segments stay empty.

## Timezone math (`zonedTime.ts`)

| Export                                             | Contract                                                                                                       |
| -------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| `utcIsoToWall(iso, tz)`                            | UTC ISO-8601 → `Wall` parts in `tz`; `null` for empty/unparseable                                              |
| `wallToUtcIso(wall, tz)` / `wallToUtcMs(wall, tz)` | Wall parts in `tz` → UTC ISO string / epoch-ms; `''`/`null` for invalid                                        |
| `isValidWall(wall)`                                | Real calendar datetime check (leap years included)                                                             |
| `daysInMonth(y, m)`                                | Days in month 1–12; `0` for out-of-range month                                                                 |
| `zoneOffsetLabel(tz, atMs?)`                       | Human label for the offset in effect at `atMs` (defaults to now), e.g. `GMT+5:30`; falls back to the IANA name |

Ambiguity conventions, fixed by the iterative-offset algorithm:

- **Spring DST gap** (nonexistent wall time): resolves shifted forward past the gap — the instant after it.
- **Autumn fall-back** (ambiguous wall time): resolves to the earlier (daylight-time) occurrence.
- Wall→UTC assembles instants with `setUTCFullYear`, **never** `Date.UTC(y, …)` — the latter silently remaps years 0–99 into the 1900s.

## Usage

```svelte
<DatetimePicker
	label="Terminus of delivery"
	bind:value={doc.data.termin}
/>
```

The zone follows the user automatically: `Europe/Warsaw` typing `15:00` commits `14:00Z` in winter and `13:00Z` in summer.

In embed contexts (filter chips, grid cells) pass `compact` to render the bare segment field only — no label, footer, or actions; a `label` still feeds the group's aria-label. `PeriodPicker` embeds one compact picker per bound this way.

For a `date`-typed field (or any calendar-date entry) pass `granularity="date"`:

```svelte
<DatetimePicker
	label="Hire date"
	granularity="date"
	bind:value={doc.data.hire_date}
/>
```

The segments show `YYYY–MM–DD` only; the committed value is the typed calendar date verbatim — `2026-08-15` in, `2026-08-15` out, whatever the zone.

## Testing

- Unit: `pnpm test` (Vitest `server` project) — `zonedTime.spec.ts` covers half-hour and quarter-hour offsets, DST summer/winter, midnight rollovers both directions, the two ambiguity conventions, leap months, and invalid input.
- Component: the stories run as tests in the `storybook` project (headless Chromium via `@storybook/addon-vitest`). Stories assert placeholder states, UTC display conversion, typing-to-commit, arrow-key bumps, day clamping, DST display in New York, `Now`/`Clear`, the partial-edit hold over a set value, the midnight commit for a typed date without time, `Clear` after a partial edit, disabled state, the settings-store fallback, the calendar panel (day selection preserving time, quick-slot commits, month navigation without committing), and the date granularity (date-only segments, verbatim `YYYY-MM-DD` commits, hidden time slots, day-pick commit, today's date on `Now`).

## Quirks

- The store's `timezone` may briefly be `null` before `loadSettings()` completes; the picker resolves to the browser zone for that window rather than rendering nothing.
- The footer prints whatever string the caller bound — a pre-populated value without milliseconds displays exactly as supplied; committed values carry milliseconds.
