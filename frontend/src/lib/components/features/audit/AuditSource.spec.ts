// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect, vi } from 'vitest';
import {
	buildAuditQuery,
	listAudit,
	rollbackMutation,
	AuditError,
	type AuditListParams
} from './AuditSource.js';
import type { HistoryResponse, RollbackResponse } from '$lib/datasource/types.js';

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

const SAMPLE_LIST: HistoryResponse = {
	data: [
		{
			id: '01MUT1',
			domain: 'hr',
			doc_type: 'Employee',
			doc_id: 'abc123',
			idx: 1,
			action: 'create',
			actioner_id: 'account-1',
			arguments: { content: { name: 'Alice' } },
			channel: 'session',
			cause_kind: 'request',
			cause_trace: '01MUT1',
			emitted_at: '2025-01-01T00:00:00Z'
		}
	],
	meta: { count: 1, more: false }
};

const SAMPLE_ROLLBACK: RollbackResponse = {
	id: 'abc123',
	domain: 'hr',
	doc_type: 'Employee',
	mut_id: '01MUT9',
	content: { name: 'Alice' },
	created_at: '2025-01-01T00:00:00Z'
};

// ── buildAuditQuery ───────────────────────────────────────────────────────

describe('buildAuditQuery', () => {
	it('builds page, items, and sort params', () => {
		const params: AuditListParams = { page: 2, items: 25, sort: ['-emitted_at'] };
		const qs = buildAuditQuery(params);
		expect(qs).toContain('page=2');
		expect(qs).toContain('items=25');
		expect(qs).toContain('sort=-emitted_at');
	});

	it('maps filters to filters[key] params', () => {
		const qs = buildAuditQuery({ filters: { action__eq: 'create', domain__eq: 'hr' } });
		expect(qs).toContain('filters%5Baction__eq%5D=create');
		expect(qs).toContain('filters%5Bdomain__eq%5D=hr');
	});

	it('JSON-encodes an array filter value', () => {
		const qs = buildAuditQuery({ filters: { emitted_at__between: ['2026-01-01', '2026-12-31'] } });
		expect(qs).toContain(
			`filters%5Bemitted_at__between%5D=${encodeURIComponent(JSON.stringify(['2026-01-01', '2026-12-31']))}`
		);
	});

	it('skips empty and null filter values', () => {
		const qs = buildAuditQuery({ filters: { action__eq: '', domain__eq: null } });
		expect(qs).toBe('');
	});

	it('returns an empty string for empty params', () => {
		expect(buildAuditQuery({})).toBe('');
	});
});

// ── listAudit ─────────────────────────────────────────────────────────────

describe('listAudit', () => {
	it('calls GET /Api/Audit and returns the parsed response', async () => {
		const fetchFn = fetchStub(SAMPLE_LIST);
		const res = await listAudit({ page: 1, items: 25 }, fetchFn);
		expect(res).toEqual(SAMPLE_LIST);
		expect(fetchFn).toHaveBeenCalledWith('/Api/Audit?page=1&items=25');
	});

	it('throws an AuditError with the status on failure', async () => {
		const fetchFn = fetchStub({ error: 'Forbidden' }, 403);
		await expect(listAudit({}, fetchFn)).rejects.toMatchObject({
			name: 'AuditError',
			status: 403,
			message: 'Forbidden'
		});
	});

	it('falls back to statusText when the body has no message', async () => {
		const fetchFn = fetchStub({}, 500);
		await expect(listAudit({}, fetchFn)).rejects.toMatchObject({ status: 500 });
	});
});

// ── rollbackMutation ──────────────────────────────────────────────────────

describe('rollbackMutation', () => {
	it('POSTs to the global rollback endpoint and returns the response', async () => {
		const fetchFn = fetchStub(SAMPLE_ROLLBACK);
		const res = await rollbackMutation('01MUT1', fetchFn);
		expect(res).toEqual(SAMPLE_ROLLBACK);
		expect(fetchFn).toHaveBeenCalledWith('/Api/Audit/01MUT1/rollback', { method: 'POST' });
	});

	it('surfaces backend error messages verbatim', async () => {
		const fetchFn = fetchStub({ error: 'Rollback to a delete mutation is not allowed' }, 422);
		await expect(rollbackMutation('01MUT1', fetchFn)).rejects.toMatchObject({
			status: 422,
			message: 'Rollback to a delete mutation is not allowed'
		});
	});
});

describe('AuditError', () => {
	it('carries the HTTP status', () => {
		const err = new AuditError(403, 'Forbidden');
		expect(err.status).toBe(403);
		expect(err.message).toBe('Forbidden');
	});
});
