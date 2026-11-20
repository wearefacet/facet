// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Pure duration math for `DurationInput`: the unit table, the total-to-parts
 * and parts-to-total conversions, and the free-form duration parser. The
 * component keeps the keyboard state machine, the drag handling, and all DOM
 * work.
 */
import * as m from '$lib/paraglide/messages';

export type UnitKey = 'd' | 'h' | 'm' | 's';

export interface UnitDef {
	label: string;
	short: string;
	mult: number;
	cap: number;
	len: number;
}

export const UNITS: Record<UnitKey, UnitDef> = {
	d: {
		label: m.common_duration_days(),
		short: m.common_duration_days(),
		mult: 86400,
		cap: 999,
		len: 3
	},
	h: {
		label: m.common_duration_hours(),
		short: m.common_duration_hours(),
		mult: 3600,
		cap: 23,
		len: 2
	},
	m: {
		label: m.common_duration_minutes(),
		short: m.common_duration_minutes_short(),
		mult: 60,
		cap: 59,
		len: 2
	},
	s: {
		label: m.common_duration_seconds(),
		short: m.common_duration_seconds_short(),
		mult: 1,
		cap: 59,
		len: 2
	}
};

export function toParts(total: number, u: UnitKey[]): number[] {
	let rest = Math.max(0, Math.floor(total));
	return u.map((key) => {
		const v = Math.floor(rest / UNITS[key].mult);
		rest -= v * UNITS[key].mult;
		return v;
	});
}

export function fromParts(nums: number[], u: UnitKey[]): number {
	return nums.reduce((acc, v, i) => acc + v * UNITS[u[i]].mult, 0);
}

/** Parse a pasted/typed free-form duration string into seconds. */
export function parseDuration(raw: unknown): number | null {
	if (raw == null) return null;
	const str = String(raw).trim().toLowerCase();
	if (!str) return null;

	// Colon clock form: "26:30", "1:02:03", "1:02:03:04" — least significant
	// segment is seconds, then minutes, hours, days.
	if (/^\d+(:\d+)+$/.test(str)) {
		const mults = [1, 60, 3600, 86400];
		return str
			.split(':')
			.map(Number)
			.reverse()
			.reduce((acc, p, i) => acc + p * (mults[i] ?? 0), 0);
	}

	// Bare integer: seconds.
	if (/^\d+$/.test(str)) return Number(str);

	// Labelled form: "1d 2h30m", "1 hour 5 min", "90 sec"
	const re = /(\d+(?:\.\d+)?)\s*(days?|d|hours?|hrs?|h|minutes?|mins?|m|seconds?|secs?|s)/g;
	let total = 0;
	let hit = false;
	let match: RegExpExecArray | null;
	while ((match = re.exec(str)) !== null) {
		hit = true;
		const n = parseFloat(match[1]);
		const u = match[2][0] as UnitKey;
		total += n * UNITS[u].mult;
	}
	return hit ? Math.round(total) : null;
}
