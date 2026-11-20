// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Pure month-grid math for the datetime picker's calendar panel.
 *
 * `monthCells` builds the fixed 42-cell grid (six weeks) for one displayed
 * month. The week starts on Monday. Days before the 1st and after the last
 * day come from the previous and next month. `CalendarPanel.svelte` feeds
 * the displayed month in; the spec asserts the current behavior.
 */
import { daysInMonth, utcIsoToWall, type Wall } from '$lib/zonedTime.js';

/** One day button in the 42-cell month grid. */
export interface CalendarCell {
	/** Full calendar year of the day. */
	y: number;
	/** Month 1-12 of the day. */
	m: number;
	/** Day of month 1-31. */
	d: number;
	/** True when the day belongs to the previous or next month. */
	out: boolean;
	/** True when the day is the same calendar date as `todayWall`. */
	today: boolean;
	/** True when the day is the same calendar date as the selected wall time. */
	selected: boolean;
}

function sameWall(w: Wall | null, y: number, m: number, d: number): boolean {
	return Boolean(w && w.y === y && w.m === m && w.d === d);
}

/**
 * Build the 42-cell grid for the displayed month.
 *
 * `wall` is the selected wall datetime; `todayWall` is the captured current
 * one. Both may be null — the matching flags stay false then. The first cell
 * is the Monday of the week that contains the 1st of the month.
 */
export function monthCells(
	viewY: number,
	viewM: number,
	wall: Wall | null,
	todayWall: Wall | null
): CalendarCell[] {
	const firstDow = (new Date(Date.UTC(viewY, viewM - 1, 1)).getUTCDay() + 6) % 7;
	const dim = daysInMonth(viewY, viewM);
	const prevM = viewM === 1 ? 12 : viewM - 1;
	const prevY = viewM === 1 ? viewY - 1 : viewY;
	const nextM = viewM === 12 ? 1 : viewM + 1;
	const nextY = viewM === 12 ? viewY + 1 : viewY;
	const prevDim = daysInMonth(prevY, prevM);
	const cells: CalendarCell[] = [];
	for (let i = 0; i < 42; i++) {
		const n = i - firstDow + 1;
		let y = viewY;
		let m = viewM;
		let d = n;
		let out = false;
		if (n < 1) {
			y = prevY;
			m = prevM;
			d = prevDim + n;
			out = true;
		} else if (n > dim) {
			y = nextY;
			m = nextM;
			d = n - dim;
			out = true;
		}
		cells.push({
			y,
			m,
			d,
			out,
			today: sameWall(todayWall, y, m, d),
			selected: sameWall(wall, y, m, d)
		});
	}
	return cells;
}

/** Wall-clock parts of the current instant in `tz`. Falls back to the epoch when the zone does not resolve. */
export function nowWall(tz: string): Wall {
	return utcIsoToWall(new Date().toISOString(), tz) ?? { y: 1970, m: 1, d: 1, h: 0, mi: 0 };
}
