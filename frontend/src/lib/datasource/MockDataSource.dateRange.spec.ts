// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { MockDataSource } from './MockDataSource.js';

interface TaskRow {
	id: string;
	title: string;
	scheduled_on: string;
	[key: string]: unknown;
}

function makeTasks(): MockDataSource<TaskRow> {
	const ds = new MockDataSource<TaskRow>('ops', 'MaintenanceTask', []);
	const seed = (id: string, title: string, scheduled_on: string): void => {
		ds.docs.set(id, {
			id,
			domain: 'ops',
			doc_type: 'MaintenanceTask',
			content: { title, scheduled_on } as unknown as TaskRow,
			version: 1,
			schema_version: 1,
			created_at: new Date().toISOString(),
			updated_at: new Date().toISOString(),
			mutations: [],
			deleted_at: null
		});
	};
	seed('t1', 'Before', '2026-02-01');
	seed('t2', 'Inside', '2026-02-25');
	seed('t3', 'After', '2026-03-10');
	return ds;
}

/**
 * The mock's scalar range path: a `date` field stores a `YYYY-MM-DD` string,
 * so `__gte` / `__lte` must compare it as a date. A date string that reads as
 * a number (`"2026-02-25"` → `NaN`, but a plain `"20260225"` would not) must
 * not fall through a money-shaped numeric coercion and reject every row.
 */
describe('MockDataSource date range filters', () => {
	it('bounds a stored date between two bounds', async () => {
		const ds = makeTasks();
		const res = await ds.list({
			filters: { scheduled_on__gte: '2026-02-20', scheduled_on__lte: '2026-02-28' }
		});
		expect(res.data.map((d) => d.data.title)).toEqual(['Inside']);
	});

	it('includes the bounds themselves', async () => {
		const ds = makeTasks();
		const res = await ds.list({
			filters: { scheduled_on__gte: '2026-02-01', scheduled_on__lte: '2026-03-10' }
		});
		expect(res.data.map((d) => d.data.title)).toEqual(['Before', 'Inside', 'After']);
	});
});
