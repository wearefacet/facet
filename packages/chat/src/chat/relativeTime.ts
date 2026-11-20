// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Relative-time and absolute-date label formatting for the chat package.
 *
 * Ported from the main application's `frontend/src/lib/utils/relativeTime.ts`
 * (the canonical implementation) minus the display-timezone machinery: the
 * package has no account-settings store, so absolute labels render in the
 * browser's local zone. The relative labels only ever compare instants, so
 * they are timezone-independent.
 *
 * The backend stores timestamps as tz-naive UTC (RFC-3339, `...Z`). Parsing
 * them with `new Date(iso)` yields an absolute instant, so the difference
 * against `Date.now()` is computed correctly regardless of the browser's
 * local timezone.
 */

import * as m from '../messages.js';

/** Format a date (ISO string or `Date`) as a short relative label ("now", "5m ago", "in 1h"). */
export function relativeTime(d: string | Date): string {
	const now = Date.now();
	const then = toInstant(d);
	// An unparseable date (null content, empty string, garbage) has no
	// instant — render a muted dash instead of a `NaN`-derived label.
	if (then == null) return '—';
	const diffMs = then - now;

	const absSec = Math.round(Math.abs(diffMs) / 1000);

	// Future within 1 minute
	if (diffMs >= 0 && absSec < 60) return m.common_time_now();
	// Past within 1 minute
	if (diffMs < 0 && absSec < 60) return m.common_time_just_now();

	// Unit definitions: [divisor, label (past/future), label when >= divisor]
	type Unit = [divisor: number, label: string];
	const units: Unit[] = [
		[60, 's'],
		[60, 'm'],
		[24, 'h'],
		[30, 'd'],
		[12, 'mo'],
		[Infinity, 'y']
	];

	let remaining = absSec;
	let label = 's';

	for (const [divisor, unitLabel] of units) {
		if (remaining < divisor) {
			label = unitLabel;
			break;
		}
		remaining = Math.round(remaining / divisor);
		label = unitLabel;
	}

	if (diffMs >= 0) {
		return m.common_time_in({ value: remaining, unit: label });
	} else {
		return m.common_time_ago({ value: remaining, unit: label });
	}
}

/**
 * Format a date as `YYYY-MM-DD HH:mm:ss` in the browser's local zone.
 * Used as the exact-datetime tooltip label for relative dates.
 */
export function formatFullDate(date: string | Date): string {
	const d = toDate(date);
	if (!d) return '—';
	const pad = (n: number, l = 2) => n.toString().padStart(l, '0');
	const mo = pad(d.getMonth() + 1);
	const da = pad(d.getDate());
	const h = pad(d.getHours());
	const mi = pad(d.getMinutes());
	const s = pad(d.getSeconds());
	return `${d.getFullYear()}-${mo}-${da} ${h}:${mi}:${s}`;
}

/**
 * Resolve a date input to a `Date`, or `null` when it carries no usable
 * instant. `null` / `undefined` / `NaN` and unparseable strings all return
 * `null` so callers can render a blank instead of a `NaN`-derived label.
 */
function toDate(d: string | Date | null | undefined): Date | null {
	if (d == null) return null;
	const parsed = typeof d === 'string' ? new Date(d) : d;
	return Number.isNaN(parsed.getTime()) ? null : parsed;
}

/** Resolve a date input to an epoch-millisecond instant, or `null`. */
function toInstant(d: string | Date | null | undefined): number | null {
	const parsed = toDate(d);
	return parsed ? parsed.getTime() : null;
}
