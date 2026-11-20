// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Calendar view — pure logic for discriminator resolution, chip placement,
 * and query predicate construction.
 *
 * All functions here are pure (no Svelte, no DOM) so they are unit-tested
 * in the Vitest `server` project. Svelte components import them as needed.
 */

import type { FieldDef, FieldType } from '$lib/doctype/types.js';
import type { CalendarDiscriminatorKind, CalendarViewConfig } from '$lib/collectionView/types.js';
import { renderTemplate } from '$lib/templating.js';

// ── Label helpers ────────────────────────────────────────────────────────

/**
 * Humanize a field key as a fallback display label.
 *
 * Splits on `_` / `-`, capitalizes the first word, lowercases the rest:
 * `scheduled_window` → `Scheduled window`, `ends-at` → `Ends at`.
 *
 * Used when a field has no explicit `title` in its definition.
 */
export function humanizeLabel(key: string): string {
	const parts = key.split(/[_-]+/).filter((p) => p.length > 0);
	if (parts.length === 0) return key;
	return parts.map((p, i) => (i === 0 ? p.charAt(0).toUpperCase() + p.slice(1) : p)).join(' ');
}

// ── Timezone-free date helpers ────────────────────────────────────────────

/**
 * Parse a `YYYY-MM-DD` string into a day bucket `{y, m, d}`.
 *
 * Calendar-date fields (`date`, `dateperiod`) are tz-naive — they represent
 * a calendar day, not an instant. Constructing a `Date` from them and
 * calling `getMonth()` would shift the day by the local UTC offset at month
 * edges. This parser keeps the literal calendar day intact.
 *
 * Returns `null` for malformed input.
 */
export function parseDay(s: unknown): { y: number; m: number; d: number } | null {
	if (typeof s !== 'string') return null;
	const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(s);
	if (!m) return null;
	const y = Number(m[1]);
	const mo = Number(m[2]);
	const d = Number(m[3]);
	if (!Number.isInteger(y) || !Number.isInteger(mo) || !Number.isInteger(d)) return null;
	if (mo < 1 || mo > 12 || d < 1 || d > 31) return null;
	return { y, m: mo, d };
}

/** Format a day bucket back to `YYYY-MM-DD` (zero-padded). */
export function formatDay(day: { y: number; m: number; d: number }): string {
	return (
		String(day.y).padStart(4, '0') +
		'-' +
		String(day.m).padStart(2, '0') +
		'-' +
		String(day.d).padStart(2, '0')
	);
}

/** Compare two day buckets lexicographically. Returns `<0`, `0`, or `>0`. */
export function compareDay(
	a: { y: number; m: number; d: number },
	b: { y: number; m: number; d: number }
): number {
	if (a.y !== b.y) return a.y - b.y;
	if (a.m !== b.m) return a.m - b.m;
	return a.d - b.d;
}

/** Return `true` iff `day` is within `[start, end]` inclusive (both ends). */
export function dayWithin(
	day: { y: number; m: number; d: number },
	start: { y: number; m: number; d: number },
	end: { y: number; m: number; d: number }
): boolean {
	return compareDay(day, start) >= 0 && compareDay(day, end) <= 0;
}

/** Add n days to a day bucket, returning a new day bucket. Negative n allowed. */
export function addDays(
	day: { y: number; m: number; d: number },
	n: number
): { y: number; m: number; d: number } {
	const date = new Date(Date.UTC(day.y, day.m - 1, day.d));
	date.setUTCDate(date.getUTCDate() + n);
	return { y: date.getUTCFullYear(), m: date.getUTCMonth() + 1, d: date.getUTCDate() };
}

/**
 * Whole-day distance `b - a` on the UTC calendar (negative when `b` is earlier).
 *
 * Use this for column arithmetic and span sizes. `compareDay` only orders
 * {y, m, d} tuples: across a month boundary it returns a month-number
 * difference (Sep 6 vs Aug 31 → 1), never a day distance.
 */
export function diffUtcDays(
	a: { y: number; m: number; d: number },
	b: { y: number; m: number; d: number }
): number {
	const ua = Date.UTC(a.y, a.m - 1, a.d);
	const ub = Date.UTC(b.y, b.m - 1, b.d);
	return Math.round((ub - ua) / 86_400_000);
}

/** Day-of-week for a day bucket, where 0 = Sunday, 1 = Monday, …, 6 = Saturday. */
export function dayOfWeek(day: { y: number; m: number; d: number }): number {
	const date = new Date(Date.UTC(day.y, day.m - 1, day.d));
	return date.getUTCDay();
}

/** Day index where Monday=0, Sunday=6 (used for week_start='monday' layouts). */
export function dayIndexMonday(day: { y: number; m: number; d: number }): number {
	return (dayOfWeek(day) + 6) % 7;
}

/** Day index where Sunday=0, …, Saturday=6 (used for week_start='sunday' layouts). */
export function dayIndexSunday(day: { y: number; m: number; d: number }): number {
	return dayOfWeek(day);
}

/** Day index given the configured `week_start`. */
export function dayIndexForWeekStart(
	day: { y: number; m: number; d: number },
	week_start: 'monday' | 'sunday'
): number {
	return week_start === 'monday' ? dayIndexMonday(day) : dayIndexSunday(day);
}

// ── Instant / time helpers ────────────────────────────────────────────────

/**
 * Parse an ISO-8601 string into a UTC epoch milliseconds number.
 * Returns `null` for malformed input. Accepts both `2026-03-15T10:30:00Z`
 * and `2026-03-15` (the latter is treated as midnight UTC).
 */
export function parseInstant(s: unknown): number | null {
	if (typeof s !== 'string') return null;
	const t = Date.parse(s);
	if (Number.isNaN(t)) return null;
	return t;
}

/** Minutes since 00:00 UTC for an instant — used for week-view vertical positioning. */
export function minutesOfDay(instant: number): number {
	const d = new Date(instant);
	return d.getUTCHours() * 60 + d.getUTCMinutes();
}

/** Day bucket for an instant, in UTC. */
export function dayOfInstant(instant: number): { y: number; m: number; d: number } {
	const d = new Date(instant);
	return { y: d.getUTCFullYear(), m: d.getUTCMonth() + 1, d: d.getUTCDate() };
}

// ── Discriminator resolution ──────────────────────────────────────────────

/**
 * Resolved interval for a calendar chip. Times are stored as UTC epoch ms
 * (nullable when the discriminator has no time component).
 *
 * - `date`-kind discriminators have `startDay`/`endDay` and null `start`/`end`.
 * - `datetime`-kind discriminators have `start`/`end` (UTC epoch ms) and
 *   matching `startDay`/`endDay` derived from the UTC date.
 *
 * `end` may equal `start` (a single-instant chip, no duration); the renderer
 * treats it as a default-duration chip in week view.
 */
export interface CalendarInterval {
	kind: CalendarDiscriminatorKind;
	start: number | null;
	end: number | null;
	startDay: { y: number; m: number; d: number } | null;
	endDay: { y: number; m: number; d: number } | null;
}

const EMPTY_INTERVAL: CalendarInterval = {
	kind: 'date',
	start: null,
	end: null,
	startDay: null,
	endDay: null
};

/**
 * Resolve the {@link CalendarDiscriminatorKind} from the discriminator
 * field's `FieldType` and whether `end_field` is configured.
 *
 * Returns `null` when the field type is not a valid discriminator — callers
 * should hide the calendar surface in that case.
 */
export function calendarDiscriminatorKind(
	discType: FieldType | undefined,
	endField: string | null | undefined
): CalendarDiscriminatorKind | null {
	if (!discType) return null;
	switch (discType) {
		case 'date':
			return endField ? 'date-range' : 'date';
		case 'datetime':
			return endField ? 'datetime-range' : 'datetime';
		case 'dateperiod':
			return 'date-range';
		case 'period':
			return 'datetime-range';
		default:
			return null;
	}
}

/** Read a `{start, end}` range object field from a document content map. */
function readRangeField(
	data: Record<string, unknown>,
	key: string
): { start?: unknown; end?: unknown } | null {
	const v = data[key];
	if (v && typeof v === 'object' && !Array.isArray(v)) {
		const obj = v as Record<string, unknown>;
		const s = obj['start'];
		const e = obj['end'];
		if (s !== undefined || e !== undefined) return { start: s, end: e };
	}
	return null;
}

/**
 * Resolve a calendar interval from a document given the configured
 * discriminator + (optional) end_field.
 *
 * Returns an empty interval (`startDay === null`) when the document is
 * missing values or they are malformed — callers should skip rendering
 * such chips.
 */
export function resolveInterval(
	data: Record<string, unknown>,
	config: CalendarViewConfig,
	kind: CalendarDiscriminatorKind
): CalendarInterval {
	switch (kind) {
		case 'date':
		case 'date-range': {
			const rangeField = readRangeField(data, config.discriminator);
			let startRaw: unknown;
			let endRaw: unknown;
			if (rangeField) {
				// `dateperiod` field — `{start, end}` object.
				startRaw = rangeField.start;
				endRaw = rangeField.end;
			} else {
				// Scalar `date` field.
				startRaw = data[config.discriminator];
				endRaw = config.end_field ? data[config.end_field] : startRaw;
			}
			const startDay = parseDay(startRaw);
			// For a single-day `date` chip, endDay equals startDay.
			const endDay = parseDay(endRaw) ?? startDay;
			if (!startDay) return EMPTY_INTERVAL;
			return { kind, start: null, end: null, startDay, endDay };
		}
		case 'datetime':
		case 'datetime-range': {
			const rangeField = readRangeField(data, config.discriminator);
			let startRaw: unknown;
			let endRaw: unknown;
			if (rangeField) {
				// `period` field — `{start, end}` ISO-8601 timestamps.
				startRaw = rangeField.start;
				endRaw = rangeField.end;
			} else {
				startRaw = data[config.discriminator];
				endRaw = config.end_field ? data[config.end_field] : startRaw;
			}
			const start = parseInstant(startRaw);
			if (start === null) return EMPTY_INTERVAL;
			// For a single-instant `datetime` chip without end, the renderer
			// uses a default duration; here we keep start === end.
			const end = parseInstant(endRaw) ?? start;
			const startDay = dayOfInstant(start);
			const endDay = end === start ? startDay : dayOfInstant(end);
			return { kind, start, end, startDay, endDay };
		}
	}
}

// ── Title template resolution ───────────────────────────────────────────

/**
 * Resolve a `title_template` against a document's content.
 *
 * A set template renders through the Jinja-subset renderer
 * (`{{ field }}`, see `$lib/templating`); an empty render falls through so
 * a chip never loses its label to a missing field.
 *
 * Without a template — or after a fallthrough — the document's stored
 * `display_name` wins (the same label the kanban card shows), then the
 * first non-empty string value of the given `fallbackFields` (the caller
 * passes the doctype's flat string fields in display order; the safety net
 * for doctypes with no display_name template). Returns the empty string
 * when no fallback is found; the grids then show the document id.
 */
export function renderCalendarTitle(
	data: Record<string, unknown>,
	template: string | null | undefined,
	fallbackFields: { key: string }[],
	displayName?: string | null
): string {
	if (template && template.trim().length > 0) {
		const rendered = renderTemplate(template, data);
		if (rendered.length > 0) return rendered;
	}
	if (displayName && displayName.length > 0) return displayName;
	for (const f of fallbackFields) {
		const v = data[f.key];
		if (typeof v === 'string' && v.length > 0) return v;
	}
	return '';
}

/** Pick the doctype's flat string/longtext fields usable as a title fallback. */
export function titleFallbackFields(fields: FieldDef[]): { key: string }[] {
	return fields
		.filter((f) => (f.type === 'string' || f.type === 'longtext') && !f.read_only)
		.map((f) => ({ key: f.key }));
}

// ── Range query predicate ─────────────────────────────────────────────────

/**
 * Build a `DocumentDataSource.list()` filter predicate covering a visible
 * window `[from, to]`.
 *
 * - For `date` fields: filter by `gte`/`lte` on the discriminator (and
 *   `end_field` when set) using `YYYY-MM-DD` strings.
 * - For `datetime` fields: filter by `gte`/`lte` using ISO-8601 strings.
 * - For `period` / `dateperiod`: native range — fall back to fetching a wide
 *   window and overlapping client-side (the MockDataSource does not support
 *   `__overlaps`); the production backend uses a GiST range overlap query.
 *
 * The `extraFilters` argument is merged in (e.g. additional user filters
 * applied on top of the calendar window).
 */
export function buildCalendarWindowFilter(
	config: CalendarViewConfig,
	kind: CalendarDiscriminatorKind,
	fromIso: string,
	toIso: string,
	extraFilters?: Record<string, unknown>
): Record<string, unknown> {
	const out: Record<string, unknown> = { ...extraFilters };

	// Native range fields (`period` / `dateperiod`) store `{start, end}` as a
	// single object, so scalar `__gte`/`__lte` filters cannot match them. The
	// production backend queries them with a GiST `__overlaps` range operator;
	// the MockDataSource does not support it, so we fetch a wide window and
	// overlap client-side (see `overlapsVisibleWindow`). Emit no window filter
	// here — the caller narrows the result set.
	const nativeRange = !config.end_field && (kind === 'date-range' || kind === 'datetime-range');
	if (nativeRange) return out;

	if (kind === 'date' || kind === 'date-range') {
		out[`${config.discriminator}__lte`] = toIso;
		if (config.end_field) {
			out[`${config.end_field}__gte`] = fromIso;
		} else {
			// Single-field `date` chip without end_field: lower-bound it by
			// the discriminator itself (covers both `date` and `dateperiod`
			// where the field is read as a scalar).
			out[`${config.discriminator}__gte`] = fromIso;
		}
	} else {
		// datetime / datetime-range.
		out[`${config.discriminator}__lte`] = toIso;
		if (config.end_field) {
			out[`${config.end_field}__gte`] = fromIso;
		} else {
			out[`${config.discriminator}__gte`] = fromIso;
		}
	}
	return out;
}

/**
 * Client-side overlap check for range-typed fields (`period`, `dateperiod`).
 * Returns true iff the document's interval intersects the visible window.
 *
 * For range fields where both start and end are dates (`date-range` resolved
 * from `dateperiod`), `fromDay`/`toDay` are compared with `dayWithin`. For
 * `period`, both sides are compared as instants.
 *
 * For single-point discriminators (no `end_field`, no `{start,end}` object),
 * this returns true (the server-side filter already covered it).
 */
export function overlapsVisibleWindow(
	interval: CalendarInterval,
	fromDay: { y: number; m: number; d: number },
	toDay: { y: number; m: number; d: number },
	fromInstant: number,
	toInstant: number
): boolean {
	if (interval.kind === 'date' || interval.kind === 'date-range') {
		if (!interval.startDay || !interval.endDay) return false;
		// Range overlaps when startDay <= toDay AND endDay >= fromDay.
		return compareDay(interval.startDay, toDay) <= 0 && compareDay(interval.endDay, fromDay) >= 0;
	}
	// datetime / datetime-range.
	if (interval.start == null) return false;
	const end = interval.end ?? interval.start;
	// Range overlaps when start <= toInstant AND end >= fromInstant.
	return interval.start <= toInstant && end >= fromInstant;
}

// ── Fetch window ──────────────────────────────────────────────────────────

const DAY_MS = 86_400_000;

/**
 * Compute the fetch window bounds for a calendar grid, in UTC epoch ms.
 *
 * The rendered grid starts on the first day of the week containing the anchor
 * day. By default the anchor is day 1 of `month` (month view): e.g. Monday
 * July 27 for August 2026 with `week_start: 'monday'`. Pass `anchorDay` to
 * anchor on a different day of the month (week view anchors on the visible
 * week's day).
 *
 * The fetch lower bound is the grid start minus one day: dates are always
 * stored in GMT and the server does not know the client's timezone, so a
 * document whose GMT date falls on the boundary day must still be fetched.
 *
 * `days` controls the window length: 42 for a 6-week month grid (default),
 * 7 for a single week.
 *
 * Returns:
 * - `gridStart` — epoch ms (UTC midnight) of the first rendered grid cell.
 * - `fetchFrom` — epoch ms of the fetch lower bound (`gridStart` minus 1 day).
 * - `fetchTo`   — epoch ms of the fetch upper bound (`gridStart` + `days` days).
 */
export function calendarFetchWindow(
	year: number,
	month: number,
	weekStart: 'monday' | 'sunday',
	days = 42,
	anchorDay = 1
): { gridStart: number; fetchFrom: number; fetchTo: number } {
	const anchor = { y: year, m: month, d: anchorDay };
	const offset = dayIndexForWeekStart(anchor, weekStart);
	const gridStart = addDays(anchor, -offset);
	const gridStartMs = Date.UTC(gridStart.y, gridStart.m - 1, gridStart.d);
	return {
		gridStart: gridStartMs,
		fetchFrom: gridStartMs - DAY_MS,
		fetchTo: gridStartMs + days * DAY_MS
	};
}

// ── Month grid geometry ───────────────────────────────────────────────────

/**
 * Compute the 6×7 month grid (42 day buckets) starting at the first cell
 * of the week containing day 1 of `month`.
 *
 * The 7-column layout always starts on `week_start`'s first day and covers
 * the visible month (with day-of-previous-month and day-of-next-month cells
 * for the leading/trailing weeks).
 */
export function monthGrid(
	year: number,
	month: number,
	week_start: 'monday' | 'sunday'
): { y: number; m: number; d: number }[] {
	const first = { y: year, m: month, d: 1 };
	const offset = dayIndexForWeekStart(first, week_start);
	const start = addDays(first, -offset);
	const cells: { y: number; m: number; d: number }[] = [];
	for (let i = 0; i < 42; i++) cells.push(addDays(start, i));
	return cells;
}

/**
 * Group month-grid cells into week rows (each an array of 7 day buckets).
 * Used for absolute-positioned range bars — each row is one week row in
 * the markup, and range bars are placed at `left = colIndex/7%` etc.
 */
export function monthGridWeeks(
	year: number,
	month: number,
	week_start: 'monday' | 'sunday'
): { y: number; m: number; d: number }[][] {
	const cells = monthGrid(year, month, week_start);
	const weeks: { y: number; m: number; d: number }[][] = [];
	for (let i = 0; i < cells.length; i += 7) weeks.push(cells.slice(i, i + 7));
	return weeks;
}

/** Returns true iff the day bucket is within the displayed month. */
export function isInMonth(
	day: { y: number; m: number; d: number },
	year: number,
	month: number
): boolean {
	return day.y === year && day.m === month;
}

// ── Range bar lane allocation (month view) ────────────────────────────────

export interface RangeBar {
	/** Index into the source `chips` array — caller can resolve back to the doc. */
	chipIndex: number;
	/** Week row index (0-based) the bar lives in. */
	rowIndex: number;
	/** Day column index the bar starts at (0..6). */
	startCol: number;
	/** Number of day columns the bar spans (1..7). */
	span: number;
	/** Allocated lane (0-based, top-to-bottom). */
	lane: number;
}

/**
 * Segment a date-range kind chip at week boundaries and allocate lanes.
 *
 * Each chip whose interval spans more than one cell within a week row becomes
 * a `RangeBar`; chips that are single-day in month view are returned by the
 * caller separately (they render below the reserved lane block, not as bars).
 *
 * Returns the bars sorted by `(rowIndex, lane)` for stable markup.
 *
 * @param chips  Resolved intervals for all documents (only `date-range` and
 *               `datetime-range` kinds produce bars; others are skipped).
 * @param weeks  Week rows from {@link monthGridWeeks}.
 */
export function allocateRangeBars(
	chips: CalendarInterval[],
	weeks: { y: number; m: number; d: number }[][]
): RangeBar[] {
	// For each chip of kind `date-range`/`datetime-range`, find the week rows
	// it intersects and emit one bar per row.
	type Pending = { chipIndex: number; rowIndex: number; startCol: number; span: number };
	const pending: Pending[] = [];

	for (let ci = 0; ci < chips.length; ci++) {
		const chip = chips[ci];
		if (chip.kind !== 'date-range' && chip.kind !== 'datetime-range') continue;
		if (!chip.startDay || !chip.endDay) continue;

		// datetime-range degrades to a chip on the start day in month view —
		// only render a bar when the start and end *day* differ.
		if (compareDay(chip.startDay, chip.endDay) === 0) continue;

		for (let ri = 0; ri < weeks.length; ri++) {
			const week = weeks[ri];
			const weekStart = week[0];
			const weekEnd = week[6];
			// Skip weeks that don't overlap the chip's day range.
			if (compareDay(chip.startDay, weekEnd) > 0) continue;
			if (compareDay(chip.endDay, weekStart) < 0) continue;

			// Clamp the bar's day range to the week.
			const barStart = compareDay(chip.startDay, weekStart) >= 0 ? chip.startDay : weekStart;
			const barEnd = compareDay(chip.endDay, weekEnd) <= 0 ? chip.endDay : weekEnd;
			// Column math needs day distances, not ordering. compareDay is a
			// field-wise comparator and returns month-number differences across
			// a month boundary, so use epoch-day arithmetic here.
			const startCol = diffUtcDays(weekStart, barStart);
			const endCol = diffUtcDays(weekStart, barEnd);
			const span = endCol - startCol + 1;
			pending.push({ chipIndex: ci, rowIndex: ri, startCol, span });
		}
	}

	// Sort by (rowIndex, startCol, chipIndex) for stable greedy lane assignment.
	pending.sort(
		(a, b) => a.rowIndex - b.rowIndex || a.startCol - b.startCol || a.chipIndex - b.chipIndex
	);

	// Per-row lane assignment (greedy, no overlap on the same lane).
	const byRow = new Map<number, { end: number; lane: number }[]>();
	const bars: RangeBar[] = [];
	for (const p of pending) {
		const lanes = byRow.get(p.rowIndex) ?? [];
		const startCol = p.startCol;
		// Find the lowest lane whose last end col is < this bar's start col.
		let assigned = -1;
		for (let li = 0; li < lanes.length; li++) {
			if (lanes[li].end < startCol) {
				assigned = li;
				lanes[li].end = startCol + p.span - 1;
				break;
			}
		}
		if (assigned === -1) {
			assigned = lanes.length;
			lanes.push({ end: startCol + p.span - 1, lane: assigned });
		}
		byRow.set(p.rowIndex, lanes);
		bars.push({
			chipIndex: p.chipIndex,
			rowIndex: p.rowIndex,
			startCol: p.startCol,
			span: p.span,
			lane: assigned
		});
	}
	return bars;
}

// ── Month cell chip capping ───────────────────────────────────────────────

export interface CellOverflow {
	/** Number of chips actually rendered in the cell. */
	visible: number;
	/** Number of chips hidden behind the "+N more" indicator. */
	hidden: number;
}

/**
 * Compute per-cell chip visibility given a cell height budget.
 *
 * The reserved lane block takes the top `lanesReserved × laneHeight` pixels
 * of every cell. Below that, single-day chips stack with `chipHeight` spacing.
 *
 * @param totalChips   Total chips assigned to the cell (excluding range bars).
 * @param cellHeight    Pixel height of the day cell.
 * @param reservedLanes Number of range-bar lanes reserved at the top of the row.
 * @param laneHeight    Pixel height of one range lane slot.
 * @param chipHeight     Pixel height of one single-day chip (incl. gap).
 * @param headerHeight   Pixel height of the day-number header inside the cell.
 */
export function cellChipVisibility(
	totalChips: number,
	cellHeight: number,
	reservedLanes: number,
	laneHeight: number,
	chipHeight: number,
	headerHeight: number
): CellOverflow {
	if (totalChips === 0) return { visible: 0, hidden: 0 };
	const reserved = reservedLanes * laneHeight;
	const available = Math.max(0, cellHeight - headerHeight - reserved);
	// Reserve one slot for the "+N more" if we have any overflow.
	const slots = Math.max(1, Math.floor(available / chipHeight));
	if (totalChips <= slots) return { visible: totalChips, hidden: 0 };
	// If only one slot is available and totalChips > 1, show 0 chips + "+N more".
	if (slots <= 1) return { visible: 0, hidden: totalChips };
	return { visible: slots - 1, hidden: totalChips - slots + 1 };
}

// ── Density grouping (collapse many chips into one group chip) ───────────

/**
 * Minimum hidden chips before a single-day cell collapses to a single
 * `X documents` group chip.
 *
 * Below this threshold the cell keeps showing individual chips + "+N more";
 * at or above it the cell is too dense and collapses to one group chip that
 * opens the list popover on click.
 */
export const GROUP_CHIP_THRESHOLD = 4;

/**
 * Decide whether a single-day cell should collapse its chips into one group.
 *
 * Collapses when the cell can show fewer than the threshold chips and at
 * least `GROUP_CHIP_THRESHOLD` chips are hidden behind the "+N more" line.
 */
export function shouldCollapseCell(totalChips: number, visibleSlots: number): boolean {
	if (totalChips < GROUP_CHIP_THRESHOLD) return false;
	return visibleSlots < GROUP_CHIP_THRESHOLD;
}

/**
 * Decide whether a week-row's multi-day range bars should collapse into one
 * `X documents` group bar (occupying the whole row).
 *
 * Multi-day ranges that cross a week boundary already become one bar per
 * week row (see {@link allocateRangeBars}); grouping is therefore per row.
 * Collapses when the allocated lane block would exceed `maxLanes` rows of
 * bars, which would otherwise eat the cell height budget.
 */
export function shouldCollapseRowBars(reservedLanes: number, maxLanes: number): boolean {
	return reservedLanes > maxLanes;
}

// ── Week view overlap clusters ────────────────────────────────────────────

export interface WeekChip {
	/** Index into the source `chips` array. */
	chipIndex: number;
	/** Day column index 0..6. */
	dayCol: number;
	/** Top offset in minutes (since midnight UTC). */
	startMin: number;
	/** Height in minutes. */
	durationMin: number;
	/** Assigned cluster (intersecting chips share a cluster index). */
	cluster: number;
	/** Column index within the cluster (0..clusterSize-1). */
	colInCluster: number;
	/** Total columns in the cluster (chip width = 1/clusterSize). */
	clusterSize: number;
}

/**
 * Group intersecting datetime intervals into clusters and split the day
 * column width uniformly within each cluster.
 *
 * Chips whose `interval.kind` is not `datetime` or `datetime-range` are
 * skipped (they live in the all-day gutter, not the hour grid).
 *
 * @param chips   Resolved intervals for all documents.
 * @param weekDays The 7 day buckets of the visible week.
 */
export function clusterWeekChips(
	chips: CalendarInterval[],
	weekDays: { y: number; m: number; d: number }[]
): WeekChip[] {
	// Group chips by day column. Only datetime-kind chips with a start time
	// participate in the hour grid.
	type Raw = { chipIndex: number; dayCol: number; startMin: number; endMin: number };
	const byDay: Raw[][] = Array.from({ length: 7 }, () => []);

	for (let ci = 0; ci < chips.length; ci++) {
		const chip = chips[ci];
		if (chip.kind !== 'datetime' && chip.kind !== 'datetime-range') continue;
		if (chip.start == null) continue;
		const startDay = chip.startDay;
		if (!startDay) continue;
		const dayCol = weekDays.findIndex((d) => compareDay(d, startDay) === 0);
		if (dayCol < 0) continue;

		const startMin = minutesOfDay(chip.start);
		// Default duration for single-instant chips: 30 minutes.
		const end = chip.end ?? chip.start;
		const isInstant = end === chip.start;
		const endMin = isInstant
			? startMin + 30
			: Math.max(startMin + 15, minutesOfDay(end) + (end < chip.start ? 24 * 60 : 0));
		byDay[dayCol].push({ chipIndex: ci, dayCol, startMin, endMin });
	}

	const out: WeekChip[] = [];
	for (let dayCol = 0; dayCol < 7; dayCol++) {
		const dayChips = byDay[dayCol].slice().sort((a, b) => a.startMin - b.startMin);
		if (dayChips.length === 0) continue;

		// Cluster by overlapping intervals.
		const clusters: Raw[][] = [];
		let currentCluster: Raw[] = [];
		let currentEnd = -1;
		for (const c of dayChips) {
			if (currentCluster.length === 0) {
				currentCluster.push(c);
				currentEnd = c.endMin;
			} else if (c.startMin < currentEnd) {
				currentCluster.push(c);
				currentEnd = Math.max(currentEnd, c.endMin);
			} else {
				clusters.push(currentCluster);
				currentCluster = [c];
				currentEnd = c.endMin;
			}
		}
		if (currentCluster.length > 0) clusters.push(currentCluster);

		// For each cluster, sort by startMin and assign columns greedily.
		for (let clusterIdx = 0; clusterIdx < clusters.length; clusterIdx++) {
			const cluster = clusters[clusterIdx].slice().sort((a, b) => a.startMin - b.startMin);
			// Standard column-splitting: each chip goes into the leftmost column
			// whose last endMin is <= its startMin.
			const cols: { end: number }[] = [];
			const assignments: number[] = [];
			for (const c of cluster) {
				let col = -1;
				for (let k = 0; k < cols.length; k++) {
					if (cols[k].end <= c.startMin) {
						col = k;
						cols[k].end = c.endMin;
						break;
					}
				}
				if (col === -1) {
					col = cols.length;
					cols.push({ end: c.endMin });
				}
				assignments.push(col);
			}
			const clusterSize = cols.length;
			for (let i = 0; i < cluster.length; i++) {
				const c = cluster[i];
				out.push({
					chipIndex: c.chipIndex,
					dayCol: c.dayCol,
					startMin: c.startMin,
					durationMin: Math.max(15, c.endMin - c.startMin),
					cluster: clusterIdx,
					colInCluster: assignments[i],
					clusterSize
				});
			}
		}
	}
	return out;
}
