// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it, vi } from 'vitest';
import {
	ImportError,
	importReportOf,
	importRowErrorOf,
	enqueueExport,
	enqueueViewExport,
	enqueueImport,
	fetchJobStatus,
	pollJob,
	downloadUrl,
	detectFormat,
	previewHeader
} from './importExportClient.js';

function jsonResponse(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'Content-Type': 'application/json' }
	});
}

function makeFetch(handler: (url: string, init?: RequestInit) => Response | Promise<Response>) {
	return vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
		const url = typeof input === 'string' ? input : input.toString();
		return handler(url, init);
	});
}

describe('enqueueExport', () => {
	it('POSTs to the export route with the CSRF header and parses the 202 body', async () => {
		const fetchImpl = makeFetch((url, init) => {
			expect(url).toBe('/Api/crm/Company/export?format=csv');
			expect(init?.method).toBe('POST');
			expect((init?.headers as Record<string, string>)['X-Requested-With']).toBe('XMLHttpRequest');
			return jsonResponse({ job_id: 'j1', status_url: '/Api/crm/Company/import_export/j1' }, 202);
		});

		const result = await enqueueExport(fetchImpl, 'crm', 'Company', 'csv');
		expect(result.jobId).toBe('j1');
		expect(result.statusUrl).toBe('/Api/crm/Company/import_export/j1');
	});

	it('throws ImportError carrying the backend message on 422', async () => {
		const fetchImpl = makeFetch(() => jsonResponse({ error: 'Unknown format: yaml' }, 422));
		await expect(enqueueExport(fetchImpl, 'crm', 'Company', 'csv')).rejects.toMatchObject({
			status: 422,
			message: 'Unknown format: yaml'
		});
	});
});

describe('enqueueViewExport', () => {
	it('POSTs the view payload as a JSON body with both headers', async () => {
		const fetchImpl = makeFetch((url, init) => {
			expect(url).toBe('/Api/crm/Company/export_view');
			expect(init?.method).toBe('POST');
			expect((init?.headers as Record<string, string>)['Content-Type']).toBe('application/json');
			expect((init?.headers as Record<string, string>)['X-Requested-With']).toBe('XMLHttpRequest');
			expect(JSON.parse(init?.body as string)).toEqual({
				columns: ['name', 'created_at'],
				sort: ['-created_at'],
				filters: { status__eq: 'open' },
				timezone: 'Europe/Paris'
			});
			return jsonResponse({ job_id: 'jv', status_url: '/Api/crm/Company/import_export/jv' }, 202);
		});

		const result = await enqueueViewExport(fetchImpl, 'crm', 'Company', {
			columns: ['name', 'created_at'],
			sort: ['-created_at'],
			filters: { status__eq: 'open' },
			timezone: 'Europe/Paris'
		});
		expect(result.jobId).toBe('jv');
		expect(result.statusUrl).toBe('/Api/crm/Company/import_export/jv');
	});

	it('surfaces the backend rejection message on 422', async () => {
		const fetchImpl = makeFetch(() =>
			jsonResponse({ error: "Unknown export column: 'ghost'" }, 422)
		);
		await expect(
			enqueueViewExport(fetchImpl, 'crm', 'Company', {
				columns: ['ghost'],
				sort: [],
				filters: {},
				timezone: 'UTC'
			})
		).rejects.toMatchObject({ status: 422, message: "Unknown export column: 'ghost'" });
	});
});

describe('enqueueImport', () => {
	it('POSTs the body with the format Content-Type and parses the row count', async () => {
		const fetchImpl = makeFetch((url, init) => {
			expect(url).toBe('/Api/crm/Company/import');
			expect((init?.headers as Record<string, string>)['Content-Type']).toBe('text/csv');
			expect(init?.body).toBe('id,name\n,x\n');
			return jsonResponse({ job_id: 'j2', row_count: 1, status_url: '/s' }, 202);
		});

		const result = await enqueueImport(fetchImpl, 'crm', 'Company', 'id,name\n,x\n', 'csv');
		expect(result.rowCount).toBe(1);
		expect(result.jobId).toBe('j2');
	});

	it('surfaces the 413 cap error message', async () => {
		const fetchImpl = makeFetch(() =>
			jsonResponse({ error: 'Upload exceeds the maximum allowed size (50 bytes)' }, 413)
		);
		await expect(enqueueImport(fetchImpl, 'c', 'd', 'x', 'json')).rejects.toBeInstanceOf(
			ImportError
		);
	});
});

describe('pollJob', () => {
	it('resolves at the terminal status with the report', async () => {
		const statuses = ['pending', 'running', 'succeeded'];
		let calls = 0;
		const fetchImpl = makeFetch(() =>
			jsonResponse({ id: 'j1', status: statuses[Math.min(calls++, 2)], result: { row_count: 2 } })
		);

		const outcome = await pollJob(fetchImpl, 'c', 'd', 'j1', {
			pollMs: 1,
			timeoutMs: 1000,
			delay: async () => {}
		});
		expect(outcome.mode).toBe('resolved');
		if (outcome.mode === 'resolved') {
			expect(outcome.status.status).toBe('succeeded');
			expect(importReportOf(outcome.status.result)?.row_count).toBe(2);
		}
	});

	it('falls back to the timeout outcome so the caller keeps the enqueue-mode surface', async () => {
		const fetchImpl = makeFetch(() => jsonResponse({ id: 'j1', status: 'running' }));
		const outcome = await pollJob(fetchImpl, 'c', 'd', 'j1', {
			pollMs: 1,
			timeoutMs: 0,
			delay: async () => {}
		});
		expect(outcome.mode).toBe('timeout');
	});

	it('resolves a failed import exposing the failing row', async () => {
		let calls = 0;
		const fetchImpl = makeFetch(() => {
			calls++;
			return calls < 3
				? jsonResponse({ id: 'j1', status: 'running' })
				: jsonResponse({
						id: 'j1',
						status: 'failed',
						result: { row: 37, field: 'email', message: 'is missing' }
					});
		});

		const outcome = await pollJob(fetchImpl, 'c', 'd', 'j1', {
			pollMs: 1,
			timeoutMs: 1000,
			delay: async () => {}
		});
		expect(outcome.mode).toBe('resolved');
		if (outcome.mode === 'resolved') {
			const rowError = importRowErrorOf(outcome.status.result);
			expect(rowError?.row).toBe(37);
			expect(rowError?.field).toBe('email');
		}
	});
});

describe('fetchJobStatus', () => {
	it('normalises null result/error for a pending job', async () => {
		const fetchImpl = makeFetch((url) => {
			expect(url).toBe('/Api/c/d/import_export/j9');
			return jsonResponse({ id: 'j9', status: 'pending', error: null, result: null });
		});
		const status = await fetchJobStatus(fetchImpl, 'c', 'd', 'j9');
		expect(status.status).toBe('pending');
		expect(status.result).toBeNull();
	});
});

describe('helpers', () => {
	it('builds the download URL', () => {
		expect(downloadUrl('crm', 'Company', 'j1')).toBe('/Api/crm/Company/import_export/j1/download');
	});

	it('detects the format from MIME then extension', () => {
		expect(detectFormat({ type: 'text/csv', name: 'x' } as File)).toBe('csv');
		expect(detectFormat({ type: 'application/json', name: 'x' } as File)).toBe('json');
		expect(detectFormat({ type: '', name: 'a.CSV' } as File)).toBe('csv');
		expect(detectFormat({ type: '', name: 'b.json' } as File)).toBe('json');
		expect(detectFormat({ type: '', name: 'c.txt' } as File)).toBeNull();
	});

	it('previews a CSV header and row count', () => {
		expect(previewHeader('id,name,price\n,Acme,"USD 1.0"\n,Beta,"USD 2.0"', 'csv')).toEqual({
			columns: ['id', 'name', 'price'],
			rowCount: 2
		});
	});

	it('previews a JSON array with id + content keys', () => {
		const preview = previewHeader(
			'[{"id": "a", "content": {"name": "x"}}, {"content": {"name": "y"}}]',
			'json'
		);
		expect(preview.columns).toEqual(['id', 'content']);
		expect(preview.rowCount).toBe(2);
	});

	it('returns an empty preview for malformed input instead of throwing', () => {
		expect(previewHeader('{oops', 'json')).toEqual({ columns: [], rowCount: null });
		expect(previewHeader('', 'csv')).toEqual({ columns: [], rowCount: null });
	});
});
