// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import {
	wallToUtcIso,
	utcIsoToWall,
	wallToUtcMs,
	daysInMonth,
	isValidWall,
	zoneOffsetLabel,
	type Wall
} from './zonedTime.js';

// ── wallToUtcIso ──────────────────────────────────────────────────────

describe('wallToUtcIso', () => {
	it('converts wall time in a fixed-offset zone (+5:30)', () => {
		const w: Wall = { y: 2026, m: 8, d: 15, h: 15, mi: 0 };
		expect(wallToUtcIso(w, 'Asia/Kolkata')).toBe('2026-08-15T09:30:00.000Z');
	});

	it('converts wall time in a quarter-hour offset zone (+5:45)', () => {
		const w: Wall = { y: 2026, m: 1, d: 1, h: 8, mi: 45 };
		expect(wallToUtcIso(w, 'Asia/Kathmandu')).toBe('2026-01-01T03:00:00.000Z');
	});

	it('converts wall time during daylight time (EDT, UTC-4)', () => {
		const w: Wall = { y: 2026, m: 7, d: 1, h: 0, mi: 0 };
		expect(wallToUtcIso(w, 'America/New_York')).toBe('2026-07-01T04:00:00.000Z');
	});

	it('converts wall time during standard time (EST, UTC-5)', () => {
		const w: Wall = { y: 2026, m: 1, d: 15, h: 0, mi: 0 };
		expect(wallToUtcIso(w, 'America/New_York')).toBe('2026-01-15T05:00:00.000Z');
	});

	it('is the identity in UTC', () => {
		const w: Wall = { y: 2026, m: 8, d: 15, h: 9, mi: 30 };
		expect(wallToUtcIso(w, 'UTC')).toBe('2026-08-15T09:30:00.000Z');
	});

	it('returns "" for an invalid calendar date (Feb 30)', () => {
		const w: Wall = { y: 2026, m: 2, d: 30, h: 10, mi: 0 };
		expect(wallToUtcIso(w, 'UTC')).toBe('');
	});

	it('returns "" for an out-of-range month', () => {
		const w: Wall = { y: 2026, m: 13, d: 1, h: 0, mi: 0 };
		expect(wallToUtcIso(w, 'UTC')).toBe('');
	});
});

// ── utcIsoToWall ──────────────────────────────────────────────────────

describe('utcIsoToWall', () => {
	it('converts a UTC instant to wall parts in a +5:30 zone', () => {
		expect(utcIsoToWall('2026-08-15T09:30:00Z', 'Asia/Kolkata')).toEqual({
			y: 2026,
			m: 8,
			d: 15,
			h: 15,
			mi: 0,
			s: 0
		});
	});

	it('rolls the date back across midnight in a negative-offset zone', () => {
		// 02:00 UTC = 22:00 of the previous day in New York (EDT).
		expect(utcIsoToWall('2026-08-15T02:00:00Z', 'America/New_York')).toEqual({
			y: 2026,
			m: 8,
			d: 14,
			h: 22,
			mi: 0,
			s: 0
		});
	});

	it('rolls the date forward across midnight in a positive-offset zone', () => {
		// 20:00 UTC = 01:45 of the next day in Kathmandu (+5:45).
		expect(utcIsoToWall('2026-08-15T20:00:00Z', 'Asia/Kathmandu')).toEqual({
			y: 2026,
			m: 8,
			d: 16,
			h: 1,
			mi: 45,
			s: 0
		});
	});

	it('returns null for empty and unparseable input', () => {
		expect(utcIsoToWall('', 'UTC')).toBeNull();
		expect(utcIsoToWall('not-a-date', 'UTC')).toBeNull();
	});
});

// ── DST ambiguity conventions ─────────────────────────────────────────

describe('DST ambiguity conventions', () => {
	it('shifts a non-existent spring-gap time forward past the gap', () => {
		// 02:30 on 2026-03-08 does not exist in New York (clocks jump 02:00 → 03:00).
		// Convention: resolve to the instant after the gap.
		const w: Wall = { y: 2026, m: 3, d: 8, h: 2, mi: 30 };
		expect(wallToUtcMs(w, 'America/New_York')).toBe(Date.UTC(2026, 2, 8, 7, 30));
	});

	it('resolves an ambiguous fall-back time to the earlier (daylight) occurrence', () => {
		// 01:30 on 2026-11-01 happens twice in New York; pick the EDT one.
		const w: Wall = { y: 2026, m: 11, d: 1, h: 1, mi: 30 };
		expect(wallToUtcMs(w, 'America/New_York')).toBe(Date.UTC(2026, 10, 1, 5, 30));
	});
});

// ── daysInMonth / isValidWall ─────────────────────────────────────────

describe('daysInMonth', () => {
	it('handles leap years', () => {
		expect(daysInMonth(2024, 2)).toBe(29);
		expect(daysInMonth(2026, 2)).toBe(28);
		expect(daysInMonth(2026, 4)).toBe(30);
		expect(daysInMonth(2026, 12)).toBe(31);
	});

	it('returns 0 for an out-of-range month', () => {
		expect(daysInMonth(2026, 0)).toBe(0);
		expect(daysInMonth(2026, 13)).toBe(0);
	});
});

describe('isValidWall', () => {
	it('accepts a real calendar datetime', () => {
		expect(isValidWall({ y: 2026, m: 2, d: 28, h: 23, mi: 59 })).toBe(true);
	});

	it('rejects out-of-range components', () => {
		expect(isValidWall({ y: 2026, m: 0, d: 1, h: 0, mi: 0 })).toBe(false);
		expect(isValidWall({ y: 2026, m: 2, d: 29, h: 0, mi: 0 })).toBe(false);
		expect(isValidWall({ y: 2026, m: 1, d: 1, h: 24, mi: 0 })).toBe(false);
		expect(isValidWall({ y: 2026, m: 1, d: 1, h: 0, mi: 60 })).toBe(false);
		expect(isValidWall({ y: 10000, m: 1, d: 1, h: 0, mi: 0 })).toBe(false);
	});
});

// ── zoneOffsetLabel ───────────────────────────────────────────────────

describe('zoneOffsetLabel', () => {
	it('labels a half-hour offset zone', () => {
		expect(zoneOffsetLabel('Asia/Kolkata')).toMatch(/^GMT\+5(:|\.5)30$/);
	});

	it('labels the offset in effect at the given instant (winter standard time)', () => {
		expect(zoneOffsetLabel('America/New_York', Date.parse('2026-01-15T05:00:00Z'))).toMatch(
			/^GMT-5(:00)?$/
		);
	});

	it('labels the offset in effect at the given instant (summer daylight time)', () => {
		expect(zoneOffsetLabel('America/New_York', Date.parse('2026-07-01T04:00:00Z'))).toMatch(
			/^GMT-4(:00)?$/
		);
	});
});
