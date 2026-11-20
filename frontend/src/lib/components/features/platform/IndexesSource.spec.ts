// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect, vi } from 'vitest';
import {
	buildIndexesQuery,
	listIndexes,
	IndexesError,
	type IndexListParams
} from './IndexesSource.js';
import type { IndexListResponse } from './IndexesSource.js';

// ── Helpers ───────────────────────────────────────────────────────────────

function jsonResponse(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'Content-Type': 'application/json' }
	});
}

function fetchStub(body: unknown, status = 200) {
	return vi.fn(async () => jsonResponse(body, status)) as unknown as typeof fetch;
}

const SAMPLE_LIST: IndexListResponse = {
	data: [
		{
			id: '01IDX1',
			domain: 'hr',
			doc_type: 'Employee',
			field_name: 'email',
			index_type: 'btree',
			index_name: 'idx_env_hr_01a2b3c4',
			status: 'active',
			error_message: null,
			created_at: '2026-01-10T08:00:00Z',
			updated_at: '2026-01-10T08:00:05Z'
		}
	],
	meta: { count: 1, more: false }
};

// ── buildIndexesQuery ─────────────────────────────────────────────────────

describe('buildIndexesQuery', () => {
	it('builds page, items, and sort params', () => {
		const params: IndexListParams = { page: 2, items: 25, sort: ['-updated_at'] };
		const qs = buildIndexesQuery(params);
		expect(qs).toContain('page=2');
		expect(qs).toContain('items=25');
		expect(qs).toContain('sort=-updated_at');
	});

	it('maps filters to filters[key] params', () => {
		const qs = buildIndexesQuery({ filters: { status__eq: 'error', domain__match: 'hr' } });
		expect(qs).toContain('filters%5Bstatus__eq%5D=error');
		expect(qs).toContain('filters%5Bdomain__match%5D=hr');
	});

	it('JSON-encodes an array filter value', () => {
		const qs = buildIndexesQuery({
			filters: { updated_at__between: ['2026-01-01', '2026-12-31'] }
		});
		expect(qs).toContain(
			`filters%5Bupdated_at__between%5D=${encodeURIComponent(JSON.stringify(['2026-01-01', '2026-12-31']))}`
		);
	});

	it('skips empty and null filter values', () => {
		const qs = buildIndexesQuery({ filters: { status__eq: '', domain__match: null } });
		expect(qs).toBe('');
	});

	it('returns an empty string for empty params', () => {
		expect(buildIndexesQuery({})).toBe('');
	});
});

// ── listIndexes ───────────────────────────────────────────────────────────

describe('listIndexes', () => {
	it('calls GET /Api/Indexes and returns the parsed response', async () => {
		const fetchFn = fetchStub(SAMPLE_LIST);
		const res = await listIndexes({ page: 1, items: 25 }, fetchFn);
		expect(res).toEqual(SAMPLE_LIST);
		expect(fetchFn).toHaveBeenCalledWith('/Api/Indexes?page=1&items=25');
	});

	it('omits the question mark when no params are given', async () => {
		const fetchFn = fetchStub(SAMPLE_LIST);
		await listIndexes({}, fetchFn);
		expect(fetchFn).toHaveBeenCalledWith('/Api/Indexes');
	});

	it('throws an IndexesError with the status on failure', async () => {
		const fetchFn = fetchStub({ error: 'Forbidden' }, 403);
		await expect(listIndexes({}, fetchFn)).rejects.toMatchObject({
			name: 'IndexesError',
			status: 403,
			message: 'Forbidden'
		});
	});

	it('falls back to statusText when the body has no message', async () => {
		const fetchFn = fetchStub({}, 500);
		await expect(listIndexes({}, fetchFn)).rejects.toMatchObject({ status: 500 });
	});
});

describe('IndexesError', () => {
	it('carries the HTTP status', () => {
		const err = new IndexesError(403, 'Forbidden');
		expect(err.status).toBe(403);
		expect(err.message).toBe('Forbidden');
	});
});
