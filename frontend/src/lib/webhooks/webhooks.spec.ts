// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it, vi } from 'vitest';
import {
	listCalls,
	findCall,
	replayCall,
	testWebhook,
	type CallsPage,
	type ReplayResult,
	type WebhookCallRecord,
	type WebhookTestResult
} from './webhooks.js';

const SAMPLE_CALL: WebhookCallRecord = {
	id: '01CALL1',
	webhook_id: '01WEBHOOK1',
	job_id: '01JOB1',
	event: 'updated',
	source_doc_id: 'crm.Contract.01DOC1',
	mutation_id: '01MUT1',
	attempt: 2,
	status: 'failed',
	http_status: 500,
	error: null,
	response_body: 'boom',
	duration_ms: 120,
	created_at: '2026-01-15T08:00:00Z',
	updated_at: '2026-01-15T08:01:00Z'
};

const SAMPLE_PAGE: CallsPage = {
	data: [SAMPLE_CALL],
	meta: { count: 1, more: false }
};

function jsonResponse(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'Content-Type': 'application/json' }
	});
}

function fetchStub(body: unknown, status = 200) {
	return vi.fn(async () => jsonResponse(body, status)) as unknown as typeof fetch;
}

describe('listCalls', () => {
	it('calls GET /Api/core/Webhook/:id/calls and returns the parsed page', async () => {
		const fetchFn = vi.fn(async () => jsonResponse(SAMPLE_PAGE));
		const res = await listCalls('01WEBHOOK1', { page: 2, items: 25 }, fetchFn as typeof fetch);
		expect(res).toEqual(SAMPLE_PAGE);
		expect(fetchFn).toHaveBeenCalledWith(
			'/Api/core/Webhook/01WEBHOOK1/calls?page=2&items=25',
			expect.anything()
		);
	});

	it('carries the status filter as a query param', async () => {
		const fetchFn = vi.fn(async () => jsonResponse(SAMPLE_PAGE));
		await listCalls('01WEBHOOK1', { status: 'failed' }, fetchFn as typeof fetch);
		expect(fetchFn).toHaveBeenCalledWith(
			'/Api/core/Webhook/01WEBHOOK1/calls?status=failed',
			expect.anything()
		);
	});

	it('emits no query string without params', async () => {
		const fetchFn = vi.fn(async () => jsonResponse(SAMPLE_PAGE));
		await listCalls('01WEBHOOK1', {}, fetchFn as typeof fetch);
		expect(fetchFn).toHaveBeenCalledWith('/Api/core/Webhook/01WEBHOOK1/calls', expect.anything());
	});

	it('throws with the backend error message on failure', async () => {
		const fetchFn = fetchStub({ error: 'status must be one of: pending, succeeded, failed' }, 422);
		await expect(listCalls('01WEBHOOK1', { status: 'dead' as never }, fetchFn)).rejects.toThrow(
			'status must be one of: pending, succeeded, failed'
		);
	});
});

describe('findCall', () => {
	it('calls GET /Api/core/Webhook/:id/calls/:call_id', async () => {
		const fetchFn = vi.fn(async () => jsonResponse(SAMPLE_CALL));
		const res = await findCall('01WEBHOOK1', '01CALL1', fetchFn as typeof fetch);
		expect(res).toEqual(SAMPLE_CALL);
		expect(fetchFn).toHaveBeenCalledWith(
			'/Api/core/Webhook/01WEBHOOK1/calls/01CALL1',
			expect.anything()
		);
	});

	it('surfaces a 404 through the error message', async () => {
		const fetchFn = fetchStub({ error: 'Not Found' }, 404);
		await expect(findCall('01WEBHOOK1', '01MISSING', fetchFn)).rejects.toThrow('Not Found');
	});
});

describe('replayCall', () => {
	it('POSTs to the replay endpoint and returns the 202 body', async () => {
		const body: ReplayResult = { call_id: '01CALL1', job_id: '01JOBNEW' };
		const fetchFn = vi.fn(async () => jsonResponse(body, 202));
		const res = await replayCall('01WEBHOOK1', '01CALL1', fetchFn as typeof fetch);
		expect(res).toEqual(body);
		expect(fetchFn).toHaveBeenCalledWith(
			'/Api/core/Webhook/01WEBHOOK1/calls/01CALL1/replay',
			expect.objectContaining({ method: 'POST' })
		);
	});

	it('surfaces the 422 rejection reason verbatim', async () => {
		const fetchFn = fetchStub(
			{ error: 'Replay rejected: source document not readable by bound role' },
			422
		);
		await expect(replayCall('01WEBHOOK1', '01CALL1', fetchFn)).rejects.toThrow(
			'Replay rejected: source document not readable by bound role'
		);
	});
});

describe('testWebhook', () => {
	it('POSTs to the test endpoint and returns the receiver response as data', async () => {
		const body: WebhookTestResult = {
			http_status: 401,
			response_body: 'unauthorized',
			response_headers: { 'content-type': 'text/plain' },
			transport_error: null,
			duration_ms: 88,
			signed_body: '{"event":"test"}'
		};
		const fetchFn = vi.fn(async () => jsonResponse(body, 200));
		const res = await testWebhook('01WEBHOOK1', fetchFn as typeof fetch);
		expect(res).toEqual(body);
		expect(fetchFn).toHaveBeenCalledWith(
			'/Api/core/Webhook/01WEBHOOK1/test',
			expect.objectContaining({ method: 'POST' })
		);
	});

	it('treats a Facet-side 422 as an error, not data', async () => {
		const fetchFn = fetchStub({ error: 'Webhook is disabled' }, 422);
		await expect(testWebhook('01WEBHOOK1', fetchFn)).rejects.toThrow('Webhook is disabled');
	});
});
