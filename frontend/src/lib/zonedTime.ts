// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * User-timezone datetime conversion helpers.
 *
 * Every `datetime` field value is stored as a UTC ISO-8601 (RFC-3339) string
 * normalized by the backend `DatetimeType` (see AGENTS.md → Time / Timezone).
 * The UI, however, must let the user read and enter wall-clock times in their
 * own timezone — the `core.timezone` user setting (see `doc/frontend/settings.md`),
 * with the `auto` sentinel resolving to the browser's zone.
 *
 * This module is a pure, dependency-free conversion layer between a UTC ISO-8601
 * instant and the wall-clock Y/M/D H:M parts of a given IANA timezone. It uses
 * only `Intl.DateTimeFormat` — no new dependencies.
 *
 * Ambiguity conventions (fixed by the iterative-offset algorithm below):
 * - Non-existent times inside a spring DST gap resolve to the wall-clock value
 *   shifted forward past the gap (the instant after the gap).
 * - Ambiguous times inside an autumn DST fall-back resolve to the earlier
 *   (daylight-time) occurrence.
 */

/** Wall-clock datetime components in a target timezone. */
export interface Wall {
	/** Full calendar year (e.g. 2026). */
	y: number;
	/** Month 1-12. */
	m: number;
	/** Day of month 1-31. */
	d: number;
	/** Hour 0-23. */
	h: number;
	/** Minute 0-59. */
	mi: number;
	/** Seconds 0-59. Filled by `utcIsoToWall` for display formatting; the
	 * wall→UTC entry paths stay minute-granular and ignore it. */
	s?: number;
}

const formatterCache = new Map<string, Intl.DateTimeFormat>();

function formatterFor(tz: string): Intl.DateTimeFormat {
	let fmt = formatterCache.get(tz);
	if (!fmt) {
		fmt = new Intl.DateTimeFormat('en-US', {
			timeZone: tz,
			year: 'numeric',
			month: '2-digit',
			day: '2-digit',
			hour: '2-digit',
			minute: '2-digit',
			second: '2-digit',
			hourCycle: 'h23'
		});
		formatterCache.set(tz, fmt);
	}
	return fmt;
}

/** Render a UTC epoch-ms instant as wall-clock parts in `tz`. */
function wallPartsInZone(ms: number, tz: string): Wall {
	const parts = formatterFor(tz).formatToParts(new Date(ms));
	const get = (type: string): number => {
		const part = parts.find((p) => p.type === type);
		return Number(part ? part.value : NaN);
	};
	const s = get('second');
	return {
		y: get('year'),
		m: get('month'),
		d: get('day'),
		h: get('hour'),
		mi: get('minute'),
		s: Number.isNaN(s) ? 0 : s
	};
}

/**
 * Convert a UTC ISO-8601 string to wall-clock parts in `tz`.
 * Returns `null` for empty or unparseable input.
 */
export function utcIsoToWall(iso: string, tz: string): Wall | null {
	if (!iso) return null;
	const ms = Date.parse(iso);
	if (Number.isNaN(ms)) return null;
	return wallPartsInZone(ms, tz);
}

/** Assemble a UTC epoch-ms instant from wall components (avoids the `Date.UTC` 0-99 remap). */
function wallMs(w: Wall): number {
	const dt = new Date(0);
	dt.setUTCFullYear(w.y, w.m - 1, w.d);
	dt.setUTCHours(w.h, w.mi, 0, 0);
	return dt.getTime();
}

/** UTC offset in ms in effect at the instant `ms` in `tz`. */
function offsetAtMs(ms: number, tz: string): number {
	const w = wallPartsInZone(ms, tz);
	return wallMs(w) - ms;
}

/**
 * Convert wall-clock parts in `tz` to a UTC epoch-ms instant.
 * Returns `null` when the wall components are invalid or out of range.
 * Non-existent times inside a spring DST gap resolve shifted forward past
 * the gap; ambiguous fall-back times resolve to the earlier (daylight)
 * occurrence.
 */
export function wallToUtcMs(w: Wall, tz: string): number | null {
	if (!isValidWall(w)) return null;
	const asUtc = wallMs(w);
	let utc = asUtc;
	for (let i = 0; i < 3; i++) {
		const next = asUtc - offsetAtMs(utc, tz);
		if (next === utc) break;
		utc = next;
	}
	return utc;
}

/**
 * Convert wall-clock parts in `tz` to a UTC ISO-8601 (RFC-3339) string.
 * Returns `''` when the wall components are invalid or out of range.
 */
export function wallToUtcIso(w: Wall, tz: string): string {
	const ms = wallToUtcMs(w, tz);
	return ms === null ? '' : new Date(ms).toISOString();
}

/** Number of days in the given month (1-12) of the given year. */
export function daysInMonth(y: number, m: number): number {
	if (!Number.isInteger(m) || m < 1 || m > 12) return 0;
	// Day 0 of the following month = last day of `m`.
	return new Date(Date.UTC(y, m, 0)).getUTCDate();
}

/** True when the wall components form a real calendar datetime. */
export function isValidWall(w: Wall): boolean {
	return (
		Number.isInteger(w.y) &&
		w.y >= 1 &&
		w.y <= 9999 &&
		Number.isInteger(w.m) &&
		w.m >= 1 &&
		w.m <= 12 &&
		Number.isInteger(w.d) &&
		w.d >= 1 &&
		w.d <= daysInMonth(w.y, w.m) &&
		Number.isInteger(w.h) &&
		w.h >= 0 &&
		w.h <= 23 &&
		Number.isInteger(w.mi) &&
		w.mi >= 0 &&
		w.mi <= 59
	);
}

/**
 * Human-readable zone offset label for `tz` at the instant `atMs` (defaults to
 * now), e.g. `"GMT+5:30"` or `"GMT-4"`. Falls back to the IANA name when the
 * runtime cannot resolve the zone.
 */
export function zoneOffsetLabel(tz: string, atMs: number = Date.now()): string {
	try {
		const parts = new Intl.DateTimeFormat('en-US', {
			timeZone: tz,
			timeZoneName: 'shortOffset'
		}).formatToParts(new Date(atMs));
		const label = parts.find((p) => p.type === 'timeZoneName');
		return label && label.value ? label.value : tz;
	} catch {
		return tz;
	}
}
