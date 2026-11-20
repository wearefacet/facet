// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it } from 'vitest';
import { monthCells } from './calendarGrid.js';
import type { Wall } from '$lib/zonedTime.js';

function wall(y: number, m: number, d: number): Wall {
	return { y, m, d, h: 0, mi: 0 };
}

describe('monthCells', () => {
	it('always returns 42 cells (six weeks)', () => {
		expect(monthCells(2024, 1, null, null)).toHaveLength(42);
		expect(monthCells(2026, 2, null, null)).toHaveLength(42);
	});

	it('starts on Monday when the month starts on Monday', () => {
		const cells = monthCells(2024, 1, null, null); // 2024-01-01 was a Monday
		expect(cells[0]).toEqual({ y: 2024, m: 1, d: 1, out: false, today: false, selected: false });
		expect(cells[30]).toEqual({ y: 2024, m: 1, d: 31, out: false, today: false, selected: false });
	});

	it('pads the leading days from the previous month', () => {
		const cells = monthCells(2024, 2, null, null); // 2024-02-01 was a Thursday
		expect(cells[0]).toMatchObject({ y: 2024, m: 1, d: 29, out: true });
		expect(cells[1]).toMatchObject({ y: 2024, m: 1, d: 30, out: true });
		expect(cells[2]).toMatchObject({ y: 2024, m: 1, d: 31, out: true });
		expect(cells[3]).toMatchObject({ y: 2024, m: 2, d: 1, out: false });
	});

	it('pads the trailing days from the next month', () => {
		const cells = monthCells(2024, 1, null, null); // 31 days, firstDow 0
		expect(cells[31]).toMatchObject({ y: 2024, m: 2, d: 1, out: true });
		expect(cells[41]).toMatchObject({ y: 2024, m: 2, d: 11, out: true });
	});

	it('rolls December forward into January of the next year', () => {
		const cells = monthCells(2025, 12, null, null); // 2025-12-01 was a Monday
		expect(cells[31]).toMatchObject({ y: 2026, m: 1, d: 1, out: true });
		expect(cells[41]).toMatchObject({ y: 2026, m: 1, d: 11, out: true });
	});

	it('rolls January back into December of the previous year', () => {
		const cells = monthCells(2025, 1, null, null); // 2025-01-01 was a Wednesday
		expect(cells[0]).toMatchObject({ y: 2024, m: 12, d: 30, out: true });
		expect(cells[1]).toMatchObject({ y: 2024, m: 12, d: 31, out: true });
		expect(cells[2]).toMatchObject({ y: 2025, m: 1, d: 1, out: false });
	});

	it('handles leap and non-leap Februaries', () => {
		const leap = monthCells(2024, 2, null, null); // 29 days
		expect(leap[31]).toMatchObject({ y: 2024, m: 2, d: 29, out: false });
		expect(leap[32]).toMatchObject({ y: 2024, m: 3, d: 1, out: true });
		const plain = monthCells(2023, 2, null, null); // 28 days
		expect(plain[29]).toMatchObject({ y: 2023, m: 2, d: 28, out: false });
		expect(plain[30]).toMatchObject({ y: 2023, m: 3, d: 1, out: true });
	});

	it('marks the selected calendar date', () => {
		const cells = monthCells(2026, 8, wall(2026, 8, 20), null);
		expect(cells.filter((c) => c.selected)).toEqual([
			{ y: 2026, m: 8, d: 20, out: false, today: false, selected: true }
		]);
	});

	it('marks today', () => {
		const cells = monthCells(2026, 8, null, wall(2026, 8, 10));
		expect(cells.filter((c) => c.today)).toEqual([
			{ y: 2026, m: 8, d: 10, out: false, today: true, selected: false }
		]);
	});

	it('marks nothing when both walls are null', () => {
		const cells = monthCells(2026, 8, null, null);
		expect(cells.some((c) => c.selected || c.today)).toBe(false);
	});

	it('marks out-of-month days only when they match the wall date', () => {
		// The August 2026 grid starts on Monday 2026-07-27. A selected July 27
		// marks the first cell — an out-of-month day.
		const cells = monthCells(2026, 8, wall(2026, 7, 27), null);
		expect(cells[0]).toMatchObject({ y: 2026, m: 7, d: 27, out: true, selected: true });
	});
});
