// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect, vi } from 'vitest';
import {
	listProviders,
	getProvider,
	createProvider,
	updateProvider,
	deleteProvider,
	stageClientSecret,
	OidcProvidersError
} from './OidcProvidersSource.js';

// ── Helpers ───────────────────────────────────────────────────────────────

function jsonResponse(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'Content-Type': 'application/json' }
	});
}

/** A fetch stub that records each call's init so request shapes are assertable. */
function recordingFetch(responder: (url: string, init?: RequestInit) => Response) {
	const calls: { url: string; init?: RequestInit }[] = [];
	const fn = vi.fn(async (input: string, init?: RequestInit) => {
		calls.push({ url: input, init });
		return responder(input, init);
	});
	return { fn: fn as unknown as (input: string, init?: RequestInit) => Promise<Response>, calls };
}

/** The provider content as the list route nests it under each row's `data`. */
const SAMPLE_CONTENT = {
	name: 'okta',
	label: 'Okta',
	issuer: 'https://idp.example.test',
	client_id: 'cid-1',
	client_secret: { mode: 'sealed', version: 1, set_at: '2026-01-01T00:00:00Z' },
	domains: ['example.test'],
	default_role: 'iam.Roles.editor',
	auto_provision: true,
	scopes: ['openid', 'email', 'profile'],
	enabled: true
};

/** A flat row — the shape the single-document show route returns via `data`. */
const SAMPLE_ROW = { id: '01PROVIDER', ...SAMPLE_CONTENT };

/** One list-envelope row: `{data, meta}` with the id in `meta.id` (B-196). */
function envelopeRow(id: string) {
	return { data: { ...SAMPLE_CONTENT }, meta: { id } };
}

describe('listProviders', () => {
	it('flattens the standard list envelope and returns the rows', async () => {
		const { fn, calls } = recordingFetch(() =>
			jsonResponse({
				data: [envelopeRow('01PROVIDER'), envelopeRow('01PROVIDER2')],
				meta: { count: 2, more: false }
			})
		);
		const rows = await listProviders(fn);
		expect(rows).toHaveLength(2);
		// The content flattens with the id promoted from `meta.id` (B-196).
		expect(rows[0]).toMatchObject({
			id: '01PROVIDER',
			name: 'okta',
			issuer: 'https://idp.example.test',
			enabled: true
		});
		expect(rows[1]).toMatchObject({ id: '01PROVIDER2', name: 'okta' });
		expect(calls[0].url).toBe('/Api/iam/OIDCProvider');
	});

	it('renders no rows and logs a warning on an unknown envelope', async () => {
		const warn = vi.spyOn(console, 'warn').mockImplementation(() => {});
		try {
			const { fn } = recordingFetch(() => jsonResponse({ items: [SAMPLE_ROW] }));
			const rows = await listProviders(fn);
			expect(rows).toEqual([]);
			expect(warn).toHaveBeenCalledTimes(1);
		} finally {
			warn.mockRestore();
		}
	});

	it('raises OidcProvidersError with the status on failure', async () => {
		const { fn } = recordingFetch(() => jsonResponse({ error: 'Forbidden' }, 403));
		await expect(listProviders(fn)).rejects.toMatchObject({
			name: 'OidcProvidersError',
			status: 403
		});
	});
});

describe('getProvider', () => {
	it('requests one document by id', async () => {
		const { fn, calls } = recordingFetch(() => jsonResponse(SAMPLE_ROW));
		const row = await getProvider('01PROVIDER', fn);
		expect(row.id).toBe('01PROVIDER');
		expect(calls[0].url).toBe('/Api/iam/OIDCProvider/01PROVIDER');
	});
});

describe('createProvider', () => {
	it('POSTs the fields with the CSRF header', async () => {
		const { fn, calls } = recordingFetch(() => jsonResponse({ ok: true }, 201));
		await createProvider({ name: 'okta', issuer: 'https://idp.example.test' }, fn);
		expect(calls[0].url).toBe('/Api/iam/OIDCProvider');
		expect(calls[0].init?.method).toBe('POST');
		const headers = calls[0].init?.headers as Record<string, string>;
		expect(headers['X-Requested-With']).toBe('XMLHttpRequest');
		const body = JSON.parse(calls[0].init?.body as string);
		expect(body.name).toBe('okta');
	});
});

describe('updateProvider', () => {
	it('PATCHes a sparse field set', async () => {
		const { fn, calls } = recordingFetch(() => jsonResponse({ ok: true }));
		await updateProvider('01PROVIDER', { enabled: false }, fn);
		expect(calls[0].url).toBe('/Api/iam/OIDCProvider/01PROVIDER');
		expect(calls[0].init?.method).toBe('PATCH');
		const body = JSON.parse(calls[0].init?.body as string);
		expect(body).toEqual({ enabled: false });
	});

	it('maps 422 details into fieldErrors', async () => {
		const { fn } = recordingFetch(() =>
			jsonResponse(
				{
					error: 'Document validation failed',
					details: [
						{ field: 'issuer', message: 'must be an absolute https URL', code: 'invalid_format' }
					]
				},
				422
			)
		);
		try {
			await updateProvider('01PROVIDER', { issuer: 'http://nope' }, fn);
			expect.unreachable();
		} catch (e) {
			expect(e).toBeInstanceOf(OidcProvidersError);
			const err = e as OidcProvidersError;
			expect(err.status).toBe(422);
			expect(err.fieldErrors).toHaveLength(1);
			expect(err.fieldErrors[0].field).toBe('issuer');
		}
	});
});

describe('deleteProvider', () => {
	it('DELETEs with the CSRF header', async () => {
		const { fn, calls } = recordingFetch(() => jsonResponse({ ok: true }));
		await deleteProvider('01PROVIDER', fn);
		expect(calls[0].url).toBe('/Api/iam/OIDCProvider/01PROVIDER');
		expect(calls[0].init?.method).toBe('DELETE');
		const headers = calls[0].init?.headers as Record<string, string>;
		expect(headers['X-Requested-With']).toBe('XMLHttpRequest');
	});
});

describe('stageClientSecret', () => {
	it('stages against the provider doctype and returns the handle', async () => {
		const { fn, calls } = recordingFetch(() => jsonResponse({ handle: 'sh_ABCDEF1234567890' }));
		const handle = await stageClientSecret('plaintext-never', fn);
		expect(handle).toBe('sh_ABCDEF1234567890');
		expect(calls[0].url).toBe('/Api/secrets/stage');
		const body = JSON.parse(calls[0].init?.body as string);
		expect(body.domain).toBe('iam');
		expect(body.doctype).toBe('OIDCProvider');
		expect(body.field_path).toBe('client_secret');
		expect(body.value).toBe('plaintext-never');
	});
});
