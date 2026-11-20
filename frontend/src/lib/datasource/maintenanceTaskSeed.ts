// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

// ── MaintenanceTask calendar fixture date shifting ─────────────────────────
//
// The calendar storybook needs a populated grid no matter when it is run, so
// the MaintenanceTask seed dates are shifted relative to "now" before seeding
// into the mock driver. The static `data/fixtures/ops.MaintenanceTask/documents.yml`
// is left untouched — it stays a fixed, deterministic dataset for backend
// testing — and only the in-memory copy the frontend seeds is re-anchored.
//
// Each task's `scheduled_on` day offset from a fixed anchor is preserved, so
// the relative layout (a cluster a few days around today, plus out-of-window
// outliers) is identical to the static fixture. Every date/datetime/range
// field of a task is shifted by the same number of days, keeping times of day
// and multi-day spans intact.

interface SeedDoc {
	id: string;
	content: Record<string, unknown>;
}

/** Anchor date = the earliest in-window task's `scheduled_on` (MT-1180). */
const ANCHOR = { y: 2026, m: 2, d: 25 };

/** Today's UTC day bucket. */
function todayBucket(): { y: number; m: number; d: number } {
	const n = new Date();
	return { y: n.getUTCFullYear(), m: n.getUTCMonth() + 1, d: n.getUTCDate() };
}

/** Whole-day difference `b - a` (positive when `b` is later). */
function diffDays(
	a: { y: number; m: number; d: number },
	b: { y: number; m: number; d: number }
): number {
	const da = Date.UTC(a.y, a.m - 1, a.d);
	const db = Date.UTC(b.y, b.m - 1, b.d);
	return Math.round((db - da) / 86_400_000);
}

/** Add `n` days to a UTC date, returning a new Date. */
function addDaysUTC(d: Date, n: number): Date {
	const x = new Date(d);
	x.setUTCDate(x.getUTCDate() + n);
	return x;
}

/** `YYYY-MM-DD` for a UTC date. */
function isoDate(d: Date): string {
	return (
		d.getUTCFullYear() +
		'-' +
		String(d.getUTCMonth() + 1).padStart(2, '0') +
		'-' +
		String(d.getUTCDate()).padStart(2, '0')
	);
}

/** Shift a `YYYY-MM-DD` string by `offset` days; passthrough when malformed. */
function shiftDateStr(s: unknown, offset: number): unknown {
	if (typeof s !== 'string') return s;
	const m = /^(\d{4})-(\d{2})-(\d{2})/.exec(s);
	if (!m) return s;
	const d = new Date(Date.UTC(Number(m[1]), Number(m[2]) - 1, Number(m[3])));
	return isoDate(addDaysUTC(d, offset));
}

/** Shift an ISO-8601 instant by `offset` days (time of day preserved). */
function shiftInstantStr(s: unknown, offset: number): unknown {
	if (typeof s !== 'string') return s;
	const t = Date.parse(s);
	if (Number.isNaN(t)) return s;
	return addDaysUTC(new Date(t), offset).toISOString();
}

/** Shift a `{start, end}` range object by `offset` days. */
function shiftRange(
	value: unknown,
	offset: number,
	shift: (s: unknown, n: number) => unknown
): unknown {
	if (!value || typeof value !== 'object' || Array.isArray(value)) return value;
	const obj = value as Record<string, unknown>;
	return { start: shift(obj.start, offset), end: shift(obj.end, offset) };
}

/**
 * Re-anchor the static MaintenanceTask fixture documents so their dates are
 * relative to today, preserving every task's exact day offset from the anchor
 * (a single global shift keeps relative gaps and multi-day spans intact).
 *
 * Returns new `{ id, content }` entries; the input documents are not mutated.
 */
export function shiftMaintenanceTaskDates(docs: SeedDoc[]): SeedDoc[] {
	const offset = diffDays(ANCHOR, todayBucket());
	return docs.map((doc) => {
		const content: Record<string, unknown> = { ...doc.content };
		content.scheduled_on = shiftDateStr(content.scheduled_on, offset);
		content.starts_at = shiftInstantStr(content.starts_at, offset);
		content.ends_at = shiftInstantStr(content.ends_at, offset);
		content.scheduled_window = shiftRange(content.scheduled_window, offset, shiftInstantStr);
		content.scheduled_days = shiftRange(content.scheduled_days, offset, shiftDateStr);
		return { id: doc.id, content };
	});
}
