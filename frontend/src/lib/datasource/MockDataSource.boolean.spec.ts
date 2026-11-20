// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { MockDataSource } from './MockDataSource.js';

interface TaskRow {
	id: string;
	title: string;
	completed: boolean;
	[key: string]: unknown;
}

/**
 * The mock's boolean filter path: the chips and the kanban boolean lanes
 * emit the wire strings `'true'` / `'false'` (the form the backend text
 * path parses against `content->>'field'`), so a stored boolean must
 * compare against the coerced value — not fail the strict identity check.
 */
function makeTasks(): MockDataSource<TaskRow> {
	const ds = new MockDataSource<TaskRow>('crm', 'Activity', []);
	const seed = (id: string, title: string, completed: boolean): void => {
		ds.docs.set(id, {
			id,
			domain: 'crm',
			doc_type: 'Activity',
			content: { id: undefined, title, completed } as unknown as TaskRow,
			version: 1,
			schema_version: 1,
			created_at: new Date().toISOString(),
			updated_at: new Date().toISOString(),
			mutations: [],
			deleted_at: null
		});
	};
	seed('t1', 'Call Mara', true);
	seed('t2', 'Email Alex', false);
	return ds;
}

describe('MockDataSource boolean filters', () => {
	it('matches the wire string against a stored boolean', async () => {
		const ds = makeTasks();
		const done = await ds.list({ filters: { completed__eq: 'true' } });
		expect(done.data.map((d) => d.data.title)).toEqual(['Call Mara']);
		const todo = await ds.list({ filters: { completed__eq: 'false' } });
		expect(todo.data.map((d) => d.data.title)).toEqual(['Email Alex']);
	});

	it('excludes with the wire string under ne', async () => {
		const ds = makeTasks();
		const res = await ds.list({ filters: { completed__ne: 'true' } });
		expect(res.data.map((d) => d.data.title)).toEqual(['Email Alex']);
	});

	it('still matches a real boolean filter value', async () => {
		const ds = makeTasks();
		const res = await ds.list({ filters: { completed__eq: true } });
		expect(res.data.map((d) => d.data.title)).toEqual(['Call Mara']);
	});
});
