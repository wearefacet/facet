// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import {
	parseDay,
	formatDay,
	compareDay,
	dayWithin,
	addDays,
	dayOfWeek,
	diffUtcDays,
	dayIndexMonday,
	dayIndexSunday,
	dayIndexForWeekStart,
	parseInstant,
	minutesOfDay,
	dayOfInstant,
	calendarDiscriminatorKind,
	resolveInterval,
	renderCalendarTitle,
	titleFallbackFields,
	buildCalendarWindowFilter,
	overlapsVisibleWindow,
	calendarFetchWindow,
	monthGrid,
	monthGridWeeks,
	isInMonth,
	allocateRangeBars,
	cellChipVisibility,
	clusterWeekChips,
	humanizeLabel,
	shouldCollapseCell,
	shouldCollapseRowBars,
	GROUP_CHIP_THRESHOLD
} from './discriminator.js';
import type { FieldDef } from '$lib/doctype/types.js';
import type { CalendarViewConfig } from '$lib/collectionView/types.js';

const CFG_DATE: CalendarViewConfig = {
	discriminator: 'due',
	week_start: 'monday'
};
const CFG_DATE_RANGE: CalendarViewConfig = {
	discriminator: 'start',
	end_field: 'end',
	week_start: 'monday'
};
const CFG_DATETIME: CalendarViewConfig = {
	discriminator: 'at',
	week_start: 'monday'
};
const CFG_PERIOD: CalendarViewConfig = {
	discriminator: 'window',
	week_start: 'monday'
};
const CFG_DATEPERIOD: CalendarViewConfig = {
	discriminator: 'window',
	week_start: 'monday'
};

const D25 = { y: 2026, m: 3, d: 25 };

describe('parseDay / formatDay', () => {
	it('parses a YYYY-MM-DD string', () => {
		expect(parseDay('2026-03-25')).toEqual(D25);
	});
	it('returns null for malformed input', () => {
		expect(parseDay('not-a-date')).toBeNull();
		expect(parseDay('2026/03/25')).toBeNull();
		expect(parseDay(null)).toBeNull();
		expect(parseDay(42)).toBeNull();
		expect(parseDay('2026-13-01')).toBeNull();
		expect(parseDay('2026-00-01')).toBeNull();
		expect(parseDay('2026-04-32')).toBeNull();
	});
	it('round-trips via formatDay', () => {
		expect(formatDay(parseDay('2026-03-25')!)).toBe('2026-03-25');
		expect(formatDay(parseDay('2026-12-31')!)).toBe('2026-12-31');
	});
});

describe('compareDay / dayWithin', () => {
	const D24 = { y: 2026, m: 3, d: 24 };
	const D26 = { y: 2026, m: 3, d: 26 };
	it('compares year-first then month then day', () => {
		expect(compareDay(D24, D25)).toBeLessThan(0);
		expect(compareDay(D25, D24)).toBeGreaterThan(0);
		expect(compareDay(D25, D25)).toBe(0);
	});
	it('dayWithin is inclusive on both ends', () => {
		expect(dayWithin(D24, D24, D26)).toBe(true);
		expect(dayWithin(D26, D24, D26)).toBe(true);
		expect(dayWithin(D25, D24, D26)).toBe(true);
		expect(dayWithin({ y: 2026, m: 3, d: 23 }, D24, D26)).toBe(false);
	});
});

describe('addDays', () => {
	it('adds forward across a month boundary', () => {
		expect(addDays({ y: 2026, m: 1, d: 31 }, 1)).toEqual({ y: 2026, m: 2, d: 1 });
	});
	it('adds forward across a year boundary', () => {
		expect(addDays({ y: 2026, m: 12, d: 31 }, 1)).toEqual({ y: 2027, m: 1, d: 1 });
	});
	it('subtracts across a month boundary', () => {
		expect(addDays({ y: 2026, m: 3, d: 1 }, -1)).toEqual({ y: 2026, m: 2, d: 28 });
	});
	it('handles leap days', () => {
		expect(addDays({ y: 2024, m: 2, d: 28 }, 1)).toEqual({ y: 2024, m: 2, d: 29 });
		expect(addDays({ y: 2024, m: 2, d: 29 }, 1)).toEqual({ y: 2024, m: 3, d: 1 });
	});
});

describe('dayOfWeek / dayIndexMonday / dayIndexSunday', () => {
	// 2026-03-25 is a Wednesday.
	it('returns JavaScript day-of-week (Sun=0)', () => {
		expect(dayOfWeek(D25)).toBe(3);
	});
	it('dayIndexMonday maps Mon=0..Sun=6', () => {
		expect(dayIndexMonday(D25)).toBe(2);
		expect(dayIndexMonday({ y: 2026, m: 3, d: 23 })).toBe(0); // Mon
		expect(dayIndexMonday({ y: 2026, m: 3, d: 29 })).toBe(6); // Sun
	});
	it('dayIndexSunday maps Sun=0..Sat=6', () => {
		expect(dayIndexSunday(D25)).toBe(3);
		expect(dayIndexSunday({ y: 2026, m: 3, d: 29 })).toBe(0); // Sun
		expect(dayIndexSunday({ y: 2026, m: 3, d: 28 })).toBe(6); // Sat
	});
	it('dayIndexForWeekStart dispatches correctly', () => {
		expect(dayIndexForWeekStart(D25, 'monday')).toBe(2);
		expect(dayIndexForWeekStart(D25, 'sunday')).toBe(3);
	});
});

describe('parseInstant / minutesOfDay / dayOfInstant', () => {
	it('parses ISO-8601 with Z', () => {
		expect(parseInstant('2026-03-25T10:30:00Z')).toBe(Date.UTC(2026, 2, 25, 10, 30));
	});
	it('parses bare YYYY-MM-DD as midnight UTC', () => {
		expect(parseInstant('2026-03-25')).toBe(Date.UTC(2026, 2, 25));
	});
	it('returns null for malformed', () => {
		expect(parseInstant('not-a-time')).toBeNull();
		expect(parseInstant(null)).toBeNull();
	});
	it('minutesOfDay reads UTC hours+minutes', () => {
		expect(minutesOfDay(Date.UTC(2026, 2, 25, 8, 30))).toBe(8 * 60 + 30);
		expect(minutesOfDay(Date.UTC(2026, 2, 25, 0, 0))).toBe(0);
	});
	it('dayOfInstant reads UTC date', () => {
		expect(dayOfInstant(Date.UTC(2026, 2, 25, 23, 59))).toEqual(D25);
	});
});

describe('calendarDiscriminatorKind', () => {
	it('maps date → date (no end_field)', () => {
		expect(calendarDiscriminatorKind('date', null)).toBe('date');
	});
	it('maps date + end_field → date-range', () => {
		expect(calendarDiscriminatorKind('date', 'end')).toBe('date-range');
	});
	it('maps datetime → datetime (no end_field)', () => {
		expect(calendarDiscriminatorKind('datetime', null)).toBe('datetime');
	});
	it('maps datetime + end_field → datetime-range', () => {
		expect(calendarDiscriminatorKind('datetime', 'end')).toBe('datetime-range');
	});
	it('maps dateperiod → date-range (ignores end_field)', () => {
		expect(calendarDiscriminatorKind('dateperiod', null)).toBe('date-range');
		expect(calendarDiscriminatorKind('dateperiod', 'unused')).toBe('date-range');
	});
	it('maps period → datetime-range (ignores end_field)', () => {
		expect(calendarDiscriminatorKind('period', null)).toBe('datetime-range');
		expect(calendarDiscriminatorKind('period', 'unused')).toBe('datetime-range');
	});
	it('returns null for non-discriminator types', () => {
		expect(calendarDiscriminatorKind('string', null)).toBeNull();
		expect(calendarDiscriminatorKind('integer', 'end')).toBeNull();
		expect(calendarDiscriminatorKind('duration', null)).toBeNull();
		expect(calendarDiscriminatorKind(undefined, null)).toBeNull();
	});
});

describe('resolveInterval', () => {
	it('reads a single date field', () => {
		const iv = resolveInterval({ due: '2026-03-25' }, CFG_DATE, 'date');
		expect(iv.kind).toBe('date');
		expect(iv.startDay).toEqual(D25);
		expect(iv.endDay).toEqual(D25);
		expect(iv.start).toBeNull();
		expect(iv.end).toBeNull();
	});
	it('reads a two-field date range', () => {
		const iv = resolveInterval(
			{ start: '2026-03-25', end: '2026-03-28' },
			CFG_DATE_RANGE,
			'date-range'
		);
		expect(iv.startDay).toEqual(D25);
		expect(iv.endDay).toEqual({ y: 2026, m: 3, d: 28 });
	});
	it('reads a dateperiod {start,end} object', () => {
		const iv = resolveInterval(
			{ window: { start: '2026-03-25', end: '2026-03-28' } },
			CFG_DATEPERIOD,
			'date-range'
		);
		expect(iv.startDay).toEqual(D25);
		expect(iv.endDay).toEqual({ y: 2026, m: 3, d: 28 });
	});
	it('reads a single datetime field', () => {
		const iv = resolveInterval({ at: '2026-03-25T10:30:00Z' }, CFG_DATETIME, 'datetime');
		expect(iv.start).toBe(Date.UTC(2026, 2, 25, 10, 30));
		// Single-instant chip: end falls back to start.
		expect(iv.end).toBe(iv.start);
		expect(iv.startDay).toEqual(D25);
	});
	it('reads a period {start,end} object', () => {
		const iv = resolveInterval(
			{ window: { start: '2026-03-25T10:00:00Z', end: '2026-03-25T12:00:00Z' } },
			CFG_PERIOD,
			'datetime-range'
		);
		expect(iv.start).toBe(Date.UTC(2026, 2, 25, 10));
		expect(iv.end).toBe(Date.UTC(2026, 2, 25, 12));
	});
	it('returns empty interval when the value is missing', () => {
		const iv = resolveInterval({}, CFG_DATE, 'date');
		expect(iv.startDay).toBeNull();
	});
	it('returns empty interval when malformed', () => {
		const iv = resolveInterval({ due: 'nope' }, CFG_DATE, 'date');
		expect(iv.startDay).toBeNull();
	});
});

describe('renderCalendarTitle', () => {
	it('substitutes {{ field }} placeholders', () => {
		expect(
			renderCalendarTitle({ name: 'Swap', subject: 'Filter' }, '{{ name }} {{ subject }}', [])
		).toBe('Swap Filter');
	});
	it('renders missing template fields as empty', () => {
		expect(renderCalendarTitle({ name: 'Swap' }, '{{ name }} {{ subject }}', [])).toBe('Swap ');
	});
	it('falls through to the display name when the template renders empty', () => {
		expect(renderCalendarTitle({}, '{{ missing }}', [], 'MT-1 label')).toBe('MT-1 label');
	});
	it('prefers the display name when no template is set', () => {
		const f: FieldDef[] = [{ key: 'name', type: 'string' }];
		expect(renderCalendarTitle({ name: 'Swap' }, null, titleFallbackFields(f), 'MT-1 label')).toBe(
			'MT-1 label'
		);
	});
	it('falls back to the first string-typed field when display_name is null', () => {
		const f: FieldDef[] = [
			{ key: 'id', type: 'string' },
			{ key: 'name', type: 'string' }
		];
		expect(
			renderCalendarTitle({ id: 'MT-1', name: 'Filter swap' }, null, titleFallbackFields(f))
		).toBe('MT-1');
	});
	it('falls back to the empty string when nothing is found', () => {
		expect(renderCalendarTitle({}, null, [])).toBe('');
	});
});

describe('buildCalendarWindowFilter', () => {
	it('builds gte/lte on a single date field', () => {
		expect(buildCalendarWindowFilter(CFG_DATE, 'date', '2026-03-01', '2026-03-31')).toEqual({
			due__gte: '2026-03-01',
			due__lte: '2026-03-31'
		});
	});
	it('builds gte on end_field + lte on start for a two-field date range', () => {
		expect(
			buildCalendarWindowFilter(CFG_DATE_RANGE, 'date-range', '2026-03-01', '2026-03-31')
		).toEqual({
			start__lte: '2026-03-31',
			end__gte: '2026-03-01'
		});
	});
	it('emits no window filter for a native period range (overlap client-side)', () => {
		expect(
			buildCalendarWindowFilter(CFG_PERIOD, 'datetime-range', '2026-03-01', '2026-03-31')
		).toEqual({});
	});
	it('emits no window filter for a native dateperiod range (overlap client-side)', () => {
		expect(
			buildCalendarWindowFilter(CFG_DATEPERIOD, 'date-range', '2026-03-01', '2026-03-31')
		).toEqual({});
	});
	it('merges extra filters', () => {
		expect(
			buildCalendarWindowFilter(CFG_DATE, 'date', '2026-03-01', '2026-03-31', {
				owner: 'iam.Account.alice'
			})
		).toEqual({
			owner: 'iam.Account.alice',
			due__gte: '2026-03-01',
			due__lte: '2026-03-31'
		});
	});
});

describe('overlapsVisibleWindow', () => {
	const fromDay = { y: 2026, m: 3, d: 1 };
	const toDay = { y: 2026, m: 3, d: 31 };
	const fromInstant = Date.UTC(2026, 2, 1);
	const toInstant = Date.UTC(2026, 2, 31, 23, 59);

	it('date-range overlapping the window is true', () => {
		const iv = resolveInterval(
			{ start: '2026-02-28', end: '2026-03-02' },
			CFG_DATE_RANGE,
			'date-range'
		);
		expect(overlapsVisibleWindow(iv, fromDay, toDay, fromInstant, toInstant)).toBe(true);
	});
	it('date-range entirely outside the window is false', () => {
		const iv = resolveInterval(
			{ start: '2026-02-01', end: '2026-02-05' },
			CFG_DATE_RANGE,
			'date-range'
		);
		expect(overlapsVisibleWindow(iv, fromDay, toDay, fromInstant, toInstant)).toBe(false);
	});
	it('datetime-range overlapping is true', () => {
		const iv = resolveInterval(
			{ window: { start: '2026-03-15T10:00:00Z', end: '2026-04-05T10:00:00Z' } },
			CFG_PERIOD,
			'datetime-range'
		);
		expect(overlapsVisibleWindow(iv, fromDay, toDay, fromInstant, toInstant)).toBe(true);
	});
	it('returns false for a date chip with no startDay', () => {
		const iv = resolveInterval({}, CFG_DATE, 'date');
		expect(overlapsVisibleWindow(iv, fromDay, toDay, fromInstant, toInstant)).toBe(false);
	});
});

describe('monthGrid / monthGridWeeks / isInMonth', () => {
	it('March 2026 (week_start=monday) starts on the Mon of week containing Mar 1 (a Sunday)', () => {
		// 2026-03-01 is a Sunday. Mon-week-start => first cell is 2026-02-23.
		const grid = monthGrid(2026, 3, 'monday');
		expect(grid.length).toBe(42);
		expect(grid[0]).toEqual({ y: 2026, m: 2, d: 23 });
		expect(grid[grid.length - 1]).toEqual({ y: 2026, m: 4, d: 5 });
	});
	it('March 2026 (week_start=sunday) starts on Sun Mar 1', () => {
		const grid = monthGrid(2026, 3, 'sunday');
		expect(grid[0]).toEqual({ y: 2026, m: 3, d: 1 });
	});
	it('monthGridWeeks splits into 6 weeks of 7', () => {
		const weeks = monthGridWeeks(2026, 3, 'monday');
		expect(weeks.length).toBe(6);
		weeks.forEach((w) => expect(w.length).toBe(7));
	});
	it('isInMonth flags only the displayed month', () => {
		expect(isInMonth({ y: 2026, m: 3, d: 15 }, 2026, 3)).toBe(true);
		expect(isInMonth({ y: 2026, m: 2, d: 28 }, 2026, 3)).toBe(false);
	});
});

describe('calendarFetchWindow', () => {
	const DAY_MS = 86_400_000;

	it('August 2026 (week_start=monday) fetches from the day before the grid start', () => {
		// Aug 1 2026 is a Saturday; Mon-week-start => first grid cell is Mon Jul 27.
		const w = calendarFetchWindow(2026, 8, 'monday');
		expect(w.gridStart).toBe(Date.UTC(2026, 6, 27));
		// Fetch lower bound is one day earlier (Sun Jul 26) because dates are
		// stored in GMT and the server does not know the client timezone.
		expect(w.fetchFrom).toBe(Date.UTC(2026, 6, 26));
		expect(w.fetchTo).toBe(Date.UTC(2026, 6, 27) + 42 * DAY_MS);
	});

	it('March 2026 (week_start=sunday) fetches from the day before the grid start', () => {
		// Mar 1 2026 is a Sunday; Sun-week-start => first grid cell is Sun Mar 1.
		const w = calendarFetchWindow(2026, 3, 'sunday');
		expect(w.gridStart).toBe(Date.UTC(2026, 2, 1));
		expect(w.fetchFrom).toBe(Date.UTC(2026, 1, 28));
	});

	it('fetchFrom is exactly one day before gridStart', () => {
		const w = calendarFetchWindow(2026, 8, 'monday');
		expect(w.fetchFrom).toBe(w.gridStart - DAY_MS);
	});

	it('anchors on day 1 of the month by default', () => {
		// Aug 1 2026 (Sat), monday start => grid start Mon Jul 27 (same as default).
		const wDefault = calendarFetchWindow(2026, 8, 'monday');
		const wExplicit = calendarFetchWindow(2026, 8, 'monday', 42, 1);
		expect(wExplicit).toEqual(wDefault);
	});

	it('anchors on the given anchorDay (week view)', () => {
		// Week containing Aug 15 2026 (Sat), monday start => Mon Aug 10.
		const w = calendarFetchWindow(2026, 8, 'monday', 7, 15);
		expect(w.gridStart).toBe(Date.UTC(2026, 7, 10));
		expect(w.fetchFrom).toBe(Date.UTC(2026, 7, 9));
		expect(w.fetchTo).toBe(Date.UTC(2026, 7, 10) + 7 * DAY_MS);
	});

	it('anchors on a day in the previous month trailing week', () => {
		// Week containing Jul 30 2026 (Thu), monday start => Mon Jul 27.
		const w = calendarFetchWindow(2026, 7, 'monday', 7, 30);
		expect(w.gridStart).toBe(Date.UTC(2026, 6, 27));
		expect(w.fetchTo).toBe(Date.UTC(2026, 6, 27) + 7 * DAY_MS);
	});

	it('respects the days parameter for window length', () => {
		const w7 = calendarFetchWindow(2026, 8, 'monday', 7);
		expect(w7.fetchTo - w7.gridStart).toBe(7 * DAY_MS);
		const w42 = calendarFetchWindow(2026, 8, 'monday', 42);
		expect(w42.fetchTo - w42.gridStart).toBe(42 * DAY_MS);
	});
});

describe('allocateRangeBars', () => {
	const weeks = monthGridWeeks(2026, 3, 'monday');

	// 2026-09-01 is a Tuesday, so the Monday-week-start grid opens with the
	// row 2026-08-31..2026-09-06 — a month boundary sits inside the row.
	const sepWeeks = monthGridWeeks(2026, 9, 'monday');

	it('measures day distances across month and year boundaries', () => {
		// compareDay(Sep 6, Aug 31) returns the month difference (1); the
		// real distance is 6 days.
		expect(diffUtcDays({ y: 2026, m: 8, d: 31 }, { y: 2026, m: 9, d: 6 })).toBe(6);
		expect(diffUtcDays({ y: 2026, m: 9, d: 6 }, { y: 2026, m: 8, d: 31 })).toBe(-6);
		expect(diffUtcDays({ y: 2026, m: 12, d: 31 }, { y: 2027, m: 1, d: 1 })).toBe(1);
	});

	it('places a segment on its true column when the range crosses a month boundary', () => {
		// 2026-09-06 (Sun) is the last cell of the first row; compareDay-based
		// math placed it at column 1 (Tuesday) instead of column 6.
		const chips = [
			resolveInterval(
				{ window: { start: '2026-09-06T06:00:00Z', end: '2026-09-07T18:00:00Z' } },
				CFG_PERIOD,
				'datetime-range'
			)
		];
		const bars = allocateRangeBars(chips, sepWeeks);
		expect(bars).toHaveLength(2);
		expect(bars[0].rowIndex).toBe(0);
		expect(bars[0].startCol).toBe(6);
		expect(bars[0].span).toBe(1);
		expect(bars[1].rowIndex).toBe(1);
		expect(bars[1].startCol).toBe(0);
		expect(bars[1].span).toBe(1);
	});

	it('computes the span across a month boundary inside one row', () => {
		// 2026-08-31 (Mon) → 2026-09-02 (Wed) spans 3 columns of the same row.
		const chips = [
			resolveInterval({ start: '2026-08-31', end: '2026-09-02' }, CFG_DATE_RANGE, 'date-range')
		];
		const bars = allocateRangeBars(chips, sepWeeks);
		expect(bars).toHaveLength(1);
		expect(bars[0].startCol).toBe(0);
		expect(bars[0].span).toBe(3);
	});

	it('produces a single-row bar for a single-day range that should degrade to a chip', () => {
		// Single-day range: start has same day as end. Per the impl, this is
		// skipped (renders as a chip), so no bar.
		const chips = [
			resolveInterval({ start: '2026-03-15', end: '2026-03-15' }, CFG_DATE_RANGE, 'date-range')
		];
		expect(allocateRangeBars(chips, weeks)).toEqual([]);
	});
	it('produces one bar for a multi-day range inside one week', () => {
		const chips = [
			resolveInterval({ start: '2026-03-09', end: '2026-03-11' }, CFG_DATE_RANGE, 'date-range')
		];
		const bars = allocateRangeBars(chips, weeks);
		expect(bars).toHaveLength(1);
		expect(bars[0].span).toBe(3);
		expect(bars[0].lane).toBe(0);
		expect(bars[0].startCol).toBe(0);
	});
	it('segments a multi-week range into one bar per week row', () => {
		const chips = [
			resolveInterval({ start: '2026-03-09', end: '2026-03-18' }, CFG_DATE_RANGE, 'date-range')
		];
		const bars = allocateRangeBars(chips, weeks);
		expect(bars).toHaveLength(2);
		// First bar is the rest of the first week (Mon-Sun = cols 0..6).
		expect(bars[0].rowIndex).toBe(2);
		expect(bars[0].startCol).toBe(0);
		// First week: 2026-03-09 (Mon) → 2026-03-15 (Sun) = 7 days.
		expect(bars[0].span).toBe(7);
		// Second bar starts at col 0 of the next week (Mon 2026-03-16) and
		// spans to Wed 2026-03-18 = 3 days.
		expect(bars[1].rowIndex).toBe(3);
		expect(bars[1].startCol).toBe(0);
		expect(bars[1].span).toBe(3);
	});
	it('allocates two overlapping bars to separate lanes', () => {
		// Both overlap on 2026-03-10, so they must be in different lanes.
		const chips = [
			resolveInterval({ start: '2026-03-09', end: '2026-03-12' }, CFG_DATE_RANGE, 'date-range'),
			resolveInterval({ start: '2026-03-10', end: '2026-03-13' }, CFG_DATE_RANGE, 'date-range')
		];
		const bars = allocateRangeBars(chips, weeks);
		expect(bars).toHaveLength(2);
		expect(bars[0].lane).toBe(0);
		expect(bars[1].lane).toBe(1);
	});
	it('allocates non-overlapping bars to the same lane', () => {
		const chips = [
			resolveInterval({ start: '2026-03-09', end: '2026-03-10' }, CFG_DATE_RANGE, 'date-range'),
			resolveInterval({ start: '2026-03-12', end: '2026-03-13' }, CFG_DATE_RANGE, 'date-range')
		];
		const bars = allocateRangeBars(chips, weeks);
		expect(bars).toHaveLength(2);
		expect(bars[0].lane).toBe(0);
		expect(bars[1].lane).toBe(0);
	});
	it('skips datetime chips that degrade to a single day in month view', () => {
		// datetime-range whose start and end are on the same UTC day → no bar
		// (degrades to a chip).
		const chips = [
			resolveInterval(
				{ window: { start: '2026-03-10T10:00:00Z', end: '2026-03-10T14:00:00Z' } },
				CFG_PERIOD,
				'datetime-range'
			)
		];
		expect(allocateRangeBars(chips, weeks)).toEqual([]);
	});
	it('emit a bar for a datetime-range spanning multiple days', () => {
		const chips = [
			resolveInterval(
				{ window: { start: '2026-03-10T10:00:00Z', end: '2026-03-12T14:00:00Z' } },
				CFG_PERIOD,
				'datetime-range'
			)
		];
		const bars = allocateRangeBars(chips, weeks);
		expect(bars).toHaveLength(1);
		expect(bars[0].span).toBe(3);
	});
});

describe('cellChipVisibility', () => {
	it('returns 0/0 when totalChips is 0', () => {
		expect(cellChipVisibility(0, 80, 0, 20, 18, 20)).toEqual({ visible: 0, hidden: 0 });
	});
	it('shows all chips when they fit', () => {
		// 80 - 20 (header) = 60px; laneHeight 0; chipHeight 18 → 3 chips fit, total 3.
		expect(cellChipVisibility(3, 80, 0, 20, 18, 20)).toEqual({ visible: 3, hidden: 0 });
	});
	it('caps and reserves a +N more slot', () => {
		// 60px / 18px = 3 slots; 4 chips → visible 2, hidden 2 (+2 more).
		expect(cellChipVisibility(4, 80, 0, 20, 18, 20)).toEqual({ visible: 2, hidden: 2 });
	});
	it('returns 0 visible + N hidden when only 1 slot fits', () => {
		// 30px available / 18px = 1 slot; totalChips>1 → 0 visible, hidden=4.
		expect(cellChipVisibility(4, 50, 0, 20, 18, 20)).toEqual({ visible: 0, hidden: 4 });
	});
	it('accounts for the reserved lane block at the top', () => {
		// 1 reserved lane × 20px = 20px; available = 80 - 20 (header) - 20 (lane) = 40px.
		// chipHeight 18 → 2 slots; 3 chips → visible 1, hidden 2.
		expect(cellChipVisibility(3, 80, 1, 20, 18, 20)).toEqual({ visible: 1, hidden: 2 });
	});
});

describe('clusterWeekChips', () => {
	const weekMon = [
		{ y: 2026, m: 3, d: 9 },
		{ y: 2026, m: 3, d: 10 },
		{ y: 2026, m: 3, d: 11 },
		{ y: 2026, m: 3, d: 12 },
		{ y: 2026, m: 3, d: 13 },
		{ y: 2026, m: 3, d: 14 },
		{ y: 2026, m: 3, d: 15 }
	];

	it('places one chip with clusterSize=1', () => {
		const chips = [resolveInterval({ at: '2026-03-10T10:00:00Z' }, CFG_DATETIME, 'datetime')];
		const out = clusterWeekChips(chips, weekMon);
		expect(out).toHaveLength(1);
		expect(out[0].clusterSize).toBe(1);
		expect(out[0].dayCol).toBe(1); // Mar 10 is the 2nd column of the Mon week.
		expect(out[0].startMin).toBe(10 * 60);
		expect(out[0].durationMin).toBe(30); // default for single-instant
	});
	it('splits two overlapping chips into two columns of one cluster', () => {
		// Both default to a 30-minute duration; the second starts 15 min into the
		// first, so they overlap and must be placed in two columns of one cluster.
		const chips = [
			resolveInterval({ at: '2026-03-10T10:00:00Z' }, CFG_DATETIME, 'datetime'),
			resolveInterval({ at: '2026-03-10T10:15:00Z' }, CFG_DATETIME, 'datetime')
		];
		const out = clusterWeekChips(chips, weekMon);
		expect(out).toHaveLength(2);
		expect(out[0].clusterSize).toBe(2);
		expect(out[1].clusterSize).toBe(2);
		expect(out[0].colInCluster).toBe(0);
		expect(out[1].colInCluster).toBe(1);
	});
	it('puts non-overlapping chips in separate clusters, each clusterSize=1', () => {
		const chips = [
			resolveInterval({ at: '2026-03-10T10:00:00Z' }, CFG_DATETIME, 'datetime'),
			resolveInterval({ at: '2026-03-10T14:00:00Z' }, CFG_DATETIME, 'datetime')
		];
		const out = clusterWeekChips(chips, weekMon);
		expect(out).toHaveLength(2);
		expect(out[0].clusterSize).toBe(1);
		expect(out[1].clusterSize).toBe(1);
		expect(out[0].cluster).not.toBe(out[1].cluster);
	});
	it('uses true end-min for a period', () => {
		const chips = [
			resolveInterval(
				{ window: { start: '2026-03-10T10:00:00Z', end: '2026-03-10T12:00:00Z' } },
				CFG_PERIOD,
				'datetime-range'
			)
		];
		const out = clusterWeekChips(chips, weekMon);
		expect(out).toHaveLength(1);
		expect(out[0].durationMin).toBe(120);
	});
	it('skips chips outside the visible week', () => {
		const chips = [resolveInterval({ at: '2026-02-28T10:00:00Z' }, CFG_DATETIME, 'datetime')];
		expect(clusterWeekChips(chips, weekMon)).toEqual([]);
	});
	it('skips date-kind chips (they live in the all-day gutter)', () => {
		const chips = [resolveInterval({ due: '2026-03-10' }, CFG_DATE, 'date')];
		expect(clusterWeekChips(chips, weekMon)).toEqual([]);
	});
});

describe('humanizeLabel', () => {
	it('capitalizes the first word and lower-cases the rest', () => {
		expect(humanizeLabel('scheduled_window')).toBe('Scheduled window');
	});
	it('splits on dashes and underscores', () => {
		expect(humanizeLabel('ends-at')).toBe('Ends at');
		expect(humanizeLabel('scheduled_on')).toBe('Scheduled on');
	});
	it('returns the key unchanged when it has no separator', () => {
		expect(humanizeLabel('status')).toBe('Status');
	});
	it('returns the input for an empty/separator-only key', () => {
		expect(humanizeLabel('')).toBe('');
	});
});

describe('shouldCollapseCell', () => {
	it('does not collapse when fewer than the threshold chips are present', () => {
		expect(shouldCollapseCell(GROUP_CHIP_THRESHOLD - 1, 1)).toBe(false);
	});
	it('does not collapse when all chips fit the visible slots', () => {
		expect(shouldCollapseCell(GROUP_CHIP_THRESHOLD, GROUP_CHIP_THRESHOLD)).toBe(false);
	});
	it('collapses when the chip count is at/above the threshold and slots fall below it', () => {
		expect(shouldCollapseCell(GROUP_CHIP_THRESHOLD, 1)).toBe(true);
		expect(shouldCollapseCell(GROUP_CHIP_THRESHOLD + 5, 0)).toBe(true);
	});
});

describe('shouldCollapseRowBars', () => {
	it('does not collapse when reserved lanes fit within the budget', () => {
		expect(shouldCollapseRowBars(3, 3)).toBe(false);
		expect(shouldCollapseRowBars(0, 3)).toBe(false);
	});
	it('collapses when reserved lanes exceed the budget', () => {
		expect(shouldCollapseRowBars(4, 3)).toBe(true);
		expect(shouldCollapseRowBars(6, 3)).toBe(true);
	});
});
