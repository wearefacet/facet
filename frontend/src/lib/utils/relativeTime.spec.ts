// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { formatFullDate, formatRangeValue, relativeTime } from './relativeTime.js';

const MIN = 60 * 1000;
const HOUR = 60 * MIN;
const DAY = 24 * HOUR;

describe('relativeTime', () => {
	it('formats a past instant within a minute as "just now"', () => {
		expect(relativeTime(new Date(Date.now() - 30 * 1000).toISOString())).toBe('just now');
	});

	it('formats a future instant within a minute as "now"', () => {
		expect(relativeTime(new Date(Date.now() + 30 * 1000).toISOString())).toBe('now');
	});

	it('formats minutes ago', () => {
		expect(relativeTime(new Date(Date.now() - 5 * MIN).toISOString())).toBe('5m ago');
	});

	it('formats hours ago', () => {
		expect(relativeTime(new Date(Date.now() - 3 * HOUR).toISOString())).toBe('3h ago');
	});

	it('formats days ago', () => {
		expect(relativeTime(new Date(Date.now() - 2 * DAY).toISOString())).toBe('2d ago');
	});

	it('formats a future instant', () => {
		expect(relativeTime(new Date(Date.now() + 1 * HOUR).toISOString())).toBe('in 1h');
	});

	it('accepts a Date object directly', () => {
		expect(relativeTime(new Date(Date.now() - 2 * DAY))).toBe('2d ago');
	});

	it('renders a dash for null / undefined', () => {
		expect(relativeTime(null as unknown as string)).toBe('—');
		expect(relativeTime(undefined as unknown as string)).toBe('—');
	});

	it('renders a dash for an unparseable string', () => {
		expect(relativeTime('null')).toBe('—');
		expect(relativeTime('')).toBe('—');
		expect(relativeTime('not-a-date')).toBe('—');
	});

	it('renders a dash for an invalid Date', () => {
		expect(relativeTime(new Date(NaN))).toBe('—');
	});
});

describe('formatFullDate', () => {
	it('formats an ISO string as YYYY-MM-DD HH:mm:ss in local time', () => {
		const d = new Date(2024, 0, 5, 9, 7, 3); // local
		expect(formatFullDate(d.toISOString())).toBe('2024-01-05 09:07:03');
	});

	it('accepts a Date object directly', () => {
		const d = new Date(2024, 11, 31, 23, 59, 59);
		expect(formatFullDate(d)).toBe('2024-12-31 23:59:59');
	});

	it('zero-pads month, day, hour, minute and second', () => {
		const d = new Date(2024, 2, 3, 4, 5, 6);
		expect(formatFullDate(d)).toBe('2024-03-03 04:05:06');
	});

	it('renders a dash for null / undefined / invalid input', () => {
		expect(formatFullDate(null as unknown as string)).toBe('—');
		expect(formatFullDate(undefined as unknown as string)).toBe('—');
		expect(formatFullDate('not-a-date')).toBe('—');
		expect(formatFullDate(new Date(NaN))).toBe('—');
	});
});

describe('formatFullDate with an explicit timezone', () => {
	it('renders the instant as wall time in the given zone', () => {
		expect(formatFullDate('2025-01-15T08:30:00Z', 'Europe/Warsaw')).toBe('2025-01-15 09:30:00');
	});

	it('honours DST — the summer offset in a DST zone', () => {
		expect(formatFullDate('2025-07-15T08:30:00Z', 'Europe/Warsaw')).toBe('2025-07-15 10:30:00');
	});

	it('renders negative-offset zones, rolling across midnight backwards', () => {
		// 08:30 UTC = 03:30 in New York (EST) on the same date.
		expect(formatFullDate('2025-01-15T08:30:00Z', 'America/New_York')).toBe('2025-01-15 03:30:00');
	});

	it('accepts a Date object directly', () => {
		expect(formatFullDate(new Date('2025-01-15T08:30:00Z'), 'UTC')).toBe('2025-01-15 08:30:00');
	});

	it('renders a dash for invalid input', () => {
		expect(formatFullDate('not-a-date', 'UTC')).toBe('—');
	});
});

describe('formatRangeValue', () => {
	it('renders dateperiod bounds verbatim — calendar dates never convert', () => {
		expect(formatRangeValue({ start: '2026-01-15', end: '2026-02-20' }, 'dateperiod')).toBe(
			'2026-01-15 → 2026-02-20'
		);
	});

	it('renders period bounds as wall time in the given zone', () => {
		expect(
			formatRangeValue(
				{ start: '2025-01-15T08:30:00Z', end: '2025-01-16T08:30:00Z' },
				'period',
				'Europe/Warsaw'
			)
		).toBe('2025-01-15 09:30:00 → 2025-01-16 09:30:00');
	});

	it('renders a dash for missing values and missing bounds', () => {
		expect(formatRangeValue(null, 'period')).toBe('—');
		expect(formatRangeValue('garbage', 'dateperiod')).toBe('—');
		expect(formatRangeValue({ start: '2026-01-15' }, 'dateperiod')).toBe('—');
		expect(formatRangeValue({}, 'period')).toBe('—');
	});
});
