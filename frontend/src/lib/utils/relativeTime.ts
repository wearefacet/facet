// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Relative-time and absolute-date label formatting for human-readable
 * timestamps.
 *
 * The canonical implementation lives here so the `RelativeTime` component and
 * any page/component that needs a plain string share one source of truth —
 * they must not reimplement it with subtly different output.
 *
 * The backend stores timestamps as tz-naive UTC (RFC-3339, `...Z`). Parsing
 * them with `new Date(iso)` yields an absolute instant, so the difference
 * against `Date.now()` is computed correctly regardless of the browser's
 * local timezone. Absolute labels take the display zone as a parameter —
 * surfaces pass the account's `displayTimezone()` so every timestamp follows
 * the user's `core.timezone` setting (calendar `date` values never pass
 * through here — they render verbatim).
 */

import { utcIsoToWall } from '$lib/zonedTime.js';
import * as m from '$lib/paraglide/messages';

/** Format a date (ISO string or `Date`) as a short relative label ("just now", "5m ago", "in 1h"). */
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
 * Format a date as `YYYY-MM-DD HH:mm:ss`.
 *
 * With `tz` (IANA name) the instant renders as wall time in that zone —
 * display surfaces pass the account's `displayTimezone()`. Without `tz` it
 * renders in the runtime's local zone (the standalone fallback).
 *
 * Used as the exact-datetime tooltip label for relative dates. The backend
 * stores timestamps as tz-naive UTC (`...Z`); parsing them with `new Date`
 * yields an absolute instant, so the rendered wall time is unambiguous once
 * the zone is fixed.
 */
export function formatFullDate(date: string | Date, tz?: string): string {
	const d = toDate(date);
	if (!d) return '—';
	const pad = (n: number, l = 2) => n.toString().padStart(l, '0');
	if (tz) {
		const w = utcIsoToWall(d.toISOString(), tz);
		if (!w) return '—';
		return `${pad(w.y, 4)}-${pad(w.m)}-${pad(w.d)} ${pad(w.h)}:${pad(w.mi)}:${pad(w.s ?? 0)}`;
	}
	const mo = pad(d.getMonth() + 1);
	const da = pad(d.getDate());
	const h = pad(d.getHours());
	const mi = pad(d.getMinutes());
	const s = pad(d.getSeconds());
	return `${d.getFullYear()}-${mo}-${da} ${h}:${mi}:${s}`;
}

/**
 * Format a range field value (`period` / `dateperiod` — a `{start, end}`
 * object) as `start → end`.
 *
 * `dateperiod` bounds are calendar dates (`YYYY-MM-DD`) and render verbatim —
 * they are not instants and must never pass through a timezone conversion.
 * `period` bounds are UTC instants and render in `tz` (the runtime's local
 * zone when omitted). Returns `—` when the value or either bound is missing;
 * an unparseable bound renders as `—` in its slot.
 */
export function formatRangeValue(
	value: unknown,
	kind: 'period' | 'dateperiod',
	tz?: string
): string {
	if (value == null || typeof value !== 'object') return '—';
	const obj = value as { start?: unknown; end?: unknown };
	if (obj.start == null || obj.end == null) return '—';
	if (kind === 'dateperiod') {
		return `${String(obj.start)} → ${String(obj.end)}`;
	}
	return `${formatFullDate(String(obj.start), tz)} → ${formatFullDate(String(obj.end), tz)}`;
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
