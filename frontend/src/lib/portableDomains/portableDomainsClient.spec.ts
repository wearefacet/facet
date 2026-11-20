// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it, vi } from 'vitest';
import {
	PortableDomainError,
	domainDownloadUrl,
	enqueueDomainExport,
	enqueueDomainImport,
	exportResultOf,
	fetchJobStatus,
	importReportOf,
	isBundleFile,
	pollJob
} from './portableDomainsClient.js';

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

function bundleFile(name = 'crm.facet-domain.zip'): File {
	return new File(['PK\x03\x04 bundle'], name, { type: 'application/zip' });
}

describe('enqueueDomainExport', () => {
	it('POSTs to the domain export route with the CSRF header and parses the 202 body', async () => {
		const fetchImpl = makeFetch((url, init) => {
			expect(url).toBe('/Api/core/Domain/crm/export');
			expect(init?.method).toBe('POST');
			expect((init?.headers as Record<string, string>)['X-Requested-With']).toBe('XMLHttpRequest');
			return jsonResponse({ job_id: 'j1', status_url: '/Api/core/Domain/import_export/j1' }, 202);
		});

		const result = await enqueueDomainExport(fetchImpl, 'crm');
		expect(result.jobId).toBe('j1');
		expect(result.statusUrl).toBe('/Api/core/Domain/import_export/j1');
	});

	it('carries the backend rejection on a draft domain (422)', async () => {
		const fetchImpl = makeFetch(() =>
			jsonResponse(
				{ error: "Domain 'crm' is a draft — scratch data is not portable. Publish it first." },
				422
			)
		);
		await expect(enqueueDomainExport(fetchImpl, 'crm')).rejects.toMatchObject({
			status: 422,
			message: "Domain 'crm' is a draft — scratch data is not portable. Publish it first."
		});
	});
});

describe('enqueueDomainImport', () => {
	it('POSTs the bundle with the into and merge query and parses the target', async () => {
		const file = bundleFile();
		const fetchImpl = makeFetch((url, init) => {
			expect(url).toBe('/Api/core/Domain/import?into=ops&merge=true');
			expect(init?.method).toBe('POST');
			expect((init?.headers as Record<string, string>)['X-Requested-With']).toBe('XMLHttpRequest');
			expect(init?.body).toBe(file);
			return jsonResponse(
				{ job_id: 'j2', target_domain: 'ops', status_url: '/Api/core/Domain/import_export/j2' },
				202
			);
		});

		const result = await enqueueDomainImport(fetchImpl, file, { into: 'ops', merge: true });
		expect(result.jobId).toBe('j2');
		expect(result.targetDomain).toBe('ops');
	});

	it('sends no query string without options', async () => {
		const fetchImpl = makeFetch((url) => {
			expect(url).toBe('/Api/core/Domain/import');
			return jsonResponse({ job_id: 'j3', status_url: '/s' }, 202);
		});
		const result = await enqueueDomainImport(fetchImpl, bundleFile());
		expect(result.targetDomain).toBeUndefined();
	});

	it('encodes the into parameter', async () => {
		const fetchImpl = makeFetch((url) => {
			// URLSearchParams renders the space as `+`; the form decoder on the
			// backend reads it back as one.
			expect(url).toBe('/Api/core/Domain/import?into=my+domain');
			return jsonResponse({ job_id: 'j4', status_url: '/s' }, 202);
		});
		await enqueueDomainImport(fetchImpl, bundleFile(), { into: 'my domain' });
	});

	it('surfaces the 413 cap error message', async () => {
		const fetchImpl = makeFetch(() =>
			jsonResponse({ error: 'Upload exceeds the maximum allowed size (50 bytes)' }, 413)
		);
		await expect(enqueueDomainImport(fetchImpl, bundleFile())).rejects.toBeInstanceOf(
			PortableDomainError
		);
	});
});

describe('pollJob', () => {
	it('resolves at the terminal status with the report', async () => {
		const statuses = ['pending', 'running', 'succeeded'];
		let calls = 0;
		const fetchImpl = makeFetch(() =>
			jsonResponse({
				id: 'j1',
				status: statuses[Math.min(calls++, 2)],
				result: { domain: 'ops', doctypes_created: 5 }
			})
		);

		const outcome = await pollJob(fetchImpl, 'j1', {
			pollMs: 1,
			timeoutMs: 1000,
			delay: async () => {}
		});
		expect(outcome.mode).toBe('resolved');
		if (outcome.mode === 'resolved') {
			expect(outcome.status.status).toBe('succeeded');
			expect(importReportOf(outcome.status.result)?.doctypes_created).toBe(5);
		}
	});

	it('falls back to the timeout outcome so the caller keeps the enqueue-mode surface', async () => {
		const fetchImpl = makeFetch(() => jsonResponse({ id: 'j1', status: 'running' }));
		const outcome = await pollJob(fetchImpl, 'j1', {
			pollMs: 1,
			timeoutMs: 0,
			delay: async () => {}
		});
		expect(outcome.mode).toBe('timeout');
	});

	it('resolves a failed import carrying the expected-failure message', async () => {
		let calls = 0;
		const fetchImpl = makeFetch(() => {
			calls++;
			return calls < 3
				? jsonResponse({ id: 'j1', status: 'running' })
				: jsonResponse({
						id: 'j1',
						status: 'failed',
						error: 'Version 3 is lower than the live version 5',
						result: { expected: true }
					});
		});

		const outcome = await pollJob(fetchImpl, 'j1', {
			pollMs: 1,
			timeoutMs: 1000,
			delay: async () => {}
		});
		expect(outcome.mode).toBe('resolved');
		if (outcome.mode === 'resolved') {
			expect(outcome.status.status).toBe('failed');
			expect(outcome.status.error).toBe('Version 3 is lower than the live version 5');
			expect(importReportOf(outcome.status.result)).toBeNull();
		}
	});
});

describe('fetchJobStatus', () => {
	it('normalises null result/error for a pending job', async () => {
		const fetchImpl = makeFetch((url) => {
			expect(url).toBe('/Api/core/Domain/import_export/j9');
			return jsonResponse({ id: 'j9', status: 'pending', error: null, result: null });
		});
		const status = await fetchJobStatus(fetchImpl, 'j9');
		expect(status.status).toBe('pending');
		expect(status.result).toBeNull();
	});
});

describe('helpers', () => {
	it('builds the download URL', () => {
		expect(domainDownloadUrl('j1')).toBe('/Api/core/Domain/import_export/j1/download');
	});

	it('normalises the export result only for the domain shape', () => {
		expect(exportResultOf({ doctype_count: 4, artifact_id: 'a1', format: 'zip' })).toMatchObject({
			doctype_count: 4
		});
		expect(exportResultOf({ row_count: 2 })).toBeNull();
		expect(exportResultOf(null)).toBeNull();
	});

	it('normalises the import report only for the domain shape', () => {
		expect(
			importReportOf({ domain: 'ops', doctypes_created: 5, doctypes_updated: 0 })
		).toMatchObject({ domain: 'ops' });
		expect(importReportOf({ row_count: 2, created: 2 })).toBeNull();
		expect(importReportOf(undefined)).toBeNull();
	});

	it('detects the bundle archive extensions', () => {
		expect(isBundleFile({ name: 'crm.facet-domain.zip' } as File)).toBe(true);
		expect(isBundleFile({ name: 'crm.facet-domain.tar.gz' } as File)).toBe(true);
		expect(isBundleFile({ name: 'crm.facet-domain.tgz' } as File)).toBe(true);
		expect(isBundleFile({ name: 'crm.facet-domain.TGZ' } as File)).toBe(true);
		expect(isBundleFile({ name: 'rows.csv' } as File)).toBe(false);
		expect(isBundleFile({ name: 'bundle.zip.exe' } as File)).toBe(false);
	});
});
