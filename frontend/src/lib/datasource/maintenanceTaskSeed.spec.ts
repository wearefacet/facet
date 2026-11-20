// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { shiftMaintenanceTaskDates } from './maintenanceTaskSeed.js';

// A minimal static fixture doc mirroring the shape of
// `data/fixtures/ops.MaintenanceTask/documents.yml`.
const STATIC: { id: string; content: Record<string, unknown> }[] = [
	{
		id: 'MT-1180',
		content: {
			name: 'Filter swap',
			status: 'done',
			scheduled_on: '2026-02-25',
			starts_at: '2026-02-25T08:30:00Z',
			ends_at: '2026-02-25T10:00:00Z',
			scheduled_window: { start: '2026-02-25T08:30:00Z', end: '2026-02-25T10:00:00Z' },
			scheduled_days: { start: '2026-02-25', end: '2026-02-25' }
		}
	},
	{
		id: 'MT-1188',
		content: {
			name: 'Line 3 shutdown',
			status: 'in_progress',
			scheduled_on: '2026-03-09',
			starts_at: '2026-03-09T06:00:00Z',
			ends_at: '2026-03-11T18:00:00Z',
			scheduled_window: { start: '2026-03-09T06:00:00Z', end: '2026-03-11T18:00:00Z' },
			scheduled_days: { start: '2026-03-09', end: '2026-03-11' }
		}
	}
];

describe('shiftMaintenanceTaskDates', () => {
	it('keeps the first task on the anchor day (today)', () => {
		const [first] = shiftMaintenanceTaskDates(STATIC);
		const today = new Date();
		const expected =
			today.getUTCFullYear() +
			'-' +
			String(today.getUTCMonth() + 1).padStart(2, '0') +
			'-' +
			String(today.getUTCDate()).padStart(2, '0');
		expect(first.content.scheduled_on).toBe(expected);
		expect(first.content.scheduled_days).toEqual({ start: expected, end: expected });
	});

	it('preserves the day offset between tasks', () => {
		const [first, second] = shiftMaintenanceTaskDates(STATIC);
		const diff = (a: string, b: string) => Math.round((Date.parse(b) - Date.parse(a)) / 86_400_000);
		// Static: MT-1180 on Feb 25, MT-1188 on Mar 9 → 12 days apart.
		expect(diff(String(first.content.scheduled_on), String(second.content.scheduled_on))).toBe(12);
	});

	it('preserves times of day and multi-day spans', () => {
		const [, second] = shiftMaintenanceTaskDates(STATIC);
		expect(String(second.content.starts_at).endsWith('T06:00:00.000Z')).toBe(true);
		expect(String(second.content.ends_at).endsWith('T18:00:00.000Z')).toBe(true);
		// Multi-day span (Mar 9 → Mar 11) is preserved.
		const days = second.content.scheduled_days as { start: string; end: string };
		const span = (a: string, b: string) => Math.round((Date.parse(b) - Date.parse(a)) / 86_400_000);
		expect(span(days.start, days.end)).toBe(2);
	});

	it('does not mutate the input documents', () => {
		const before = JSON.stringify(STATIC);
		shiftMaintenanceTaskDates(STATIC);
		expect(JSON.stringify(STATIC)).toBe(before);
	});
});
