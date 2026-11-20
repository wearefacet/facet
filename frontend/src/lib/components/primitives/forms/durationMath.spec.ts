// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it } from 'vitest';
import { UNITS, fromParts, parseDuration, toParts } from './durationMath.js';
import type { UnitKey } from './durationMath.js';

const DHMS: UnitKey[] = ['d', 'h', 'm', 's'];

describe('toParts', () => {
	it('splits a total across the given units, most significant first', () => {
		expect(toParts(95400, DHMS)).toEqual([1, 2, 30, 0]); // 1d 2h 30m
		expect(toParts(184500, DHMS)).toEqual([2, 3, 15, 0]); // 2d 3h 15m
		expect(toParts(3723, DHMS)).toEqual([0, 1, 2, 3]);
	});

	it('gives the whole remainder to the first unit — it is uncapped', () => {
		expect(toParts(95400, ['h', 'm', 's'])).toEqual([26, 30, 0]);
		expect(toParts(86400000, DHMS)).toEqual([1000, 0, 0, 0]);
	});

	it('floors fractional seconds', () => {
		expect(toParts(90.7, DHMS)).toEqual([0, 0, 1, 30]);
	});

	it('clamps negative totals to zero', () => {
		expect(toParts(-5, DHMS)).toEqual([0, 0, 0, 0]);
	});

	it('returns all zeros for a zero total', () => {
		expect(toParts(0, DHMS)).toEqual([0, 0, 0, 0]);
	});
});

describe('fromParts', () => {
	it('multiplies each part by its unit multiplier', () => {
		expect(fromParts([2, 3, 15, 0], DHMS)).toBe(184500);
		expect(fromParts([1, 2, 30, 0], DHMS)).toBe(95400);
	});

	it('does not apply unit caps', () => {
		expect(fromParts([0, 26, 30, 0], DHMS)).toBe(95400);
	});

	it('round-trips through toParts', () => {
		for (const total of [0, 1, 59, 60, 3723, 86399, 95400, 184500, 86400000]) {
			expect(fromParts(toParts(total, DHMS), DHMS)).toBe(total);
		}
	});
});

describe('parseDuration', () => {
	it('returns null for missing and empty input', () => {
		expect(parseDuration(null)).toBeNull();
		expect(parseDuration(undefined)).toBeNull();
		expect(parseDuration('')).toBeNull();
		expect(parseDuration('   ')).toBeNull();
	});

	it('parses a bare integer as seconds', () => {
		expect(parseDuration('90')).toBe(90);
		expect(parseDuration('0')).toBe(0);
		expect(parseDuration('0012')).toBe(12);
	});

	it('coerces non-string input through String()', () => {
		expect(parseDuration(90)).toBe(90);
	});

	it('parses the colon clock form — least significant segment is seconds', () => {
		expect(parseDuration('26:30')).toBe(1590);
		expect(parseDuration('1:02:03')).toBe(3723);
		expect(parseDuration('1:02:03:04')).toBe(93784);
		expect(parseDuration('01:02:03')).toBe(3723);
		expect(parseDuration('0:30')).toBe(30);
	});

	it('does not validate unit caps in the colon form', () => {
		expect(parseDuration('90:90')).toBe(5490);
		expect(parseDuration('999:59:59')).toBe(3599999);
	});

	it('parses labelled units, with or without spaces', () => {
		expect(parseDuration('1d 2h30m')).toBe(95400);
		expect(parseDuration('1d2h30m')).toBe(95400);
		expect(parseDuration('1 hour 5 min')).toBe(3900);
		expect(parseDuration('90 sec')).toBe(90);
		expect(parseDuration('3 days')).toBe(259200);
		expect(parseDuration('1 hr')).toBe(3600);
		expect(parseDuration('5 mins')).toBe(300);
		expect(parseDuration('2 secs')).toBe(2);
		expect(parseDuration('30s')).toBe(30);
	});

	it('is case-insensitive', () => {
		expect(parseDuration('2H')).toBe(7200);
		expect(parseDuration('1D 1H')).toBe(90000);
	});

	it('accepts decimal quantities and rounds the total', () => {
		expect(parseDuration('1.5h')).toBe(5400);
		expect(parseDuration('0.5h')).toBe(1800);
		expect(parseDuration('1.5s')).toBe(2);
		expect(parseDuration('0.4s')).toBe(0);
	});

	it('scans for number and unit pairs anywhere in the text', () => {
		expect(parseDuration('12 monkeys')).toBe(720); // "12 m" matches inside the word
		expect(parseDuration('5d 5x')).toBe(432000); // trailing junk is ignored
	});

	it('returns null when no unit term matches', () => {
		expect(parseDuration('abc')).toBeNull();
		expect(parseDuration('5x')).toBeNull();
		expect(parseDuration('-5')).toBeNull();
		expect(parseDuration('1.5')).toBeNull();
		expect(parseDuration('5:')).toBeNull();
	});
});

describe('UNITS', () => {
	it('carries the multipliers and caps the functions rely on', () => {
		expect(UNITS.d.mult).toBe(86400);
		expect(UNITS.h.mult).toBe(3600);
		expect(UNITS.m.mult).toBe(60);
		expect(UNITS.s.mult).toBe(1);
		expect(UNITS.d.cap).toBe(999);
		expect(UNITS.h.cap).toBe(23);
		expect(UNITS.m.cap).toBe(59);
		expect(UNITS.s.cap).toBe(59);
	});
});
