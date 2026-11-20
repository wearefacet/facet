// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it, vi } from 'vitest';
import { staticKey } from '../src/auth/provider.js';
import { cacheKey, memoryCache } from '../src/cache.js';
import { createFacetClient } from '../src/client.js';
import { requestJson } from '../src/http.js';

const BASE = 'https://facet.example.com';
const LIST_PATH = '/Api/crm/Company';
const DOC_ID = '01ABCDEF';

function jsonResponse(status: number, body: unknown, etag?: string): Response {
	const headers = new Headers();
	if (etag !== undefined) {
		headers.set('etag', etag);
	}
	return {
		ok: status >= 200 && status < 300,
		status,
		statusText: '',
		headers,
		text: async () => JSON.stringify(body)
	} as unknown as Response;
}

/** A 304 whose body getter throws — a cache hit must never read the body. */
function notModified(): Response {
	return {
		ok: false,
		status: 304,
		statusText: 'Not Modified',
		headers: new Headers(),
		text: async () => {
			throw new Error('a 304 hit must not read the body');
		}
	} as unknown as Response;
}

function asFetch(mock: ReturnType<typeof vi.fn>): typeof fetch {
	return mock as unknown as typeof fetch;
}

function callOf(mock: ReturnType<typeof vi.fn>, index: number): { url: URL; init: RequestInit } {
	const call = mock.mock.calls[index];
	if (!call) {
		throw new Error(`fetch was not called a ${index + 1}. time`);
	}
	return { url: call[0] as URL, init: call[1] as RequestInit };
}

function headersOf(mock: ReturnType<typeof vi.fn>, index: number): Record<string, string> {
	return callOf(mock, index).init.headers as Record<string, string>;
}

const envelope = { data: [], meta: { count: 0, more: false } };
const meta = {
	id: `crm.Company.${DOC_ID}`,
	mid: '01J9ZZZZ',
	domain: 'crm',
	doc_type: 'Company',
	version: 1,
	schema_version: 1,
	created_at: '2026-01-01T00:00:00Z',
	updated_at: '2026-01-01T00:00:00Z'
};
const listKey = cacheKey('GET', new URL(LIST_PATH, BASE));

describe('requestJson — ETag cache', () => {
	it('the first GET stores the validator and the envelope', async () => {
		const store = memoryCache();
		const fetchImpl = vi.fn().mockResolvedValue(jsonResponse(200, envelope, '"v1"'));
		await requestJson(BASE, LIST_PATH, { fetchImpl: asFetch(fetchImpl), cache: store });
		const entry = store.get(listKey);
		expect(entry?.validator).toBe('"v1"');
		expect(entry?.envelope).toEqual(envelope);
	});

	it('the second GET sends If-None-Match and serves the cached envelope on 304', async () => {
		const store = memoryCache();
		const fetchImpl = vi
			.fn()
			.mockResolvedValueOnce(jsonResponse(200, envelope, '"v1"'))
			.mockResolvedValueOnce(notModified());
		const first = await requestJson(BASE, LIST_PATH, {
			fetchImpl: asFetch(fetchImpl),
			cache: store
		});
		const second = await requestJson(BASE, LIST_PATH, {
			fetchImpl: asFetch(fetchImpl),
			cache: store
		});
		expect(headersOf(fetchImpl, 1)['if-none-match']).toBe('"v1"');
		expect(second).toEqual(first);
		expect(second).toBe(first); // the stored object — no re-parse
	});

	it('a 200 replaces the entry', async () => {
		const store = memoryCache();
		const next = { data: [{ data: { name: 'B' }, meta }], meta: { count: 1, more: false } };
		const fetchImpl = vi
			.fn()
			.mockResolvedValueOnce(jsonResponse(200, envelope, '"v1"'))
			.mockResolvedValueOnce(jsonResponse(200, next, '"v2"'))
			.mockResolvedValueOnce(notModified());
		await requestJson(BASE, LIST_PATH, { fetchImpl: asFetch(fetchImpl), cache: store });
		await requestJson(BASE, LIST_PATH, { fetchImpl: asFetch(fetchImpl), cache: store });
		const entry = store.get(listKey);
		expect(entry?.validator).toBe('"v2"');
		expect(entry?.envelope).toEqual(next);
		const third = await requestJson(BASE, LIST_PATH, {
			fetchImpl: asFetch(fetchImpl),
			cache: store
		});
		expect(headersOf(fetchImpl, 2)['if-none-match']).toBe('"v2"');
		expect(third).toEqual(next);
	});

	it('a 200 without an ETag header drops the stored entry', async () => {
		const store = memoryCache();
		const fetchImpl = vi
			.fn()
			.mockResolvedValueOnce(jsonResponse(200, envelope, '"v1"'))
			.mockResolvedValueOnce(jsonResponse(200, envelope));
		await requestJson(BASE, LIST_PATH, { fetchImpl: asFetch(fetchImpl), cache: store });
		await requestJson(BASE, LIST_PATH, { fetchImpl: asFetch(fetchImpl), cache: store });
		expect(store.get(listKey)).toBeUndefined();
	});

	it('mutating verbs never send If-None-Match and never touch the store', async () => {
		const store = memoryCache();
		const fetchImpl = vi
			.fn()
			.mockResolvedValueOnce(jsonResponse(200, envelope, '"v1"'))
			.mockResolvedValueOnce(jsonResponse(200, { data: {}, meta }))
			.mockResolvedValueOnce(jsonResponse(200, { data: {}, meta }))
			.mockResolvedValueOnce(jsonResponse(204, undefined));
		await requestJson(BASE, LIST_PATH, { fetchImpl: asFetch(fetchImpl), cache: store });
		await requestJson(BASE, LIST_PATH, {
			method: 'PATCH',
			json: { status: 'archived' },
			fetchImpl: asFetch(fetchImpl),
			cache: store
		});
		expect(headersOf(fetchImpl, 1)['if-none-match']).toBeUndefined();
		expect(store.get(cacheKey('PATCH', new URL(LIST_PATH, BASE)))).toBeUndefined();
		expect(store.get(listKey)).toBeDefined(); // the GET entry survives

		await requestJson(BASE, LIST_PATH, {
			method: 'POST',
			json: { name: 'Acme' },
			fetchImpl: asFetch(fetchImpl),
			cache: store
		});
		await requestJson(BASE, LIST_PATH, {
			method: 'DELETE',
			fetchImpl: asFetch(fetchImpl),
			cache: store
		});
		expect(headersOf(fetchImpl, 2)['if-none-match']).toBeUndefined();
		expect(headersOf(fetchImpl, 3)['if-none-match']).toBeUndefined();
	});

	it('the cache is off by default', async () => {
		const fetchImpl = vi
			.fn()
			.mockResolvedValueOnce(jsonResponse(200, envelope, '"v1"'))
			.mockResolvedValueOnce(jsonResponse(200, envelope, '"v1"'));
		await requestJson(BASE, LIST_PATH, { fetchImpl: asFetch(fetchImpl) });
		await requestJson(BASE, LIST_PATH, { fetchImpl: asFetch(fetchImpl) });
		expect(headersOf(fetchImpl, 1)['if-none-match']).toBeUndefined();
	});
});

describe('createFacetClient — cache option', () => {
	it('cache: true serves a second show() from the store', async () => {
		const docResponse = { data: { name: 'Acme' }, meta };
		const fetchImpl = vi
			.fn()
			.mockResolvedValueOnce(jsonResponse(200, docResponse, '"s1"'))
			.mockResolvedValueOnce(notModified());
		const facet = createFacetClient({
			baseUrl: BASE,
			auth: staticKey('fct_1'),
			fetchImpl: asFetch(fetchImpl),
			cache: true
		});
		const doc = facet.domain('crm').doctype('Company').doc(DOC_ID);
		const first = await doc.show();
		const second = await doc.show();
		expect(headersOf(fetchImpl, 1)['if-none-match']).toBe('"s1"');
		expect(second).toBe(first);
	});

	it('each client holds its own store', async () => {
		const docResponse = { data: { name: 'Acme' }, meta };
		const fetchImpl = vi
			.fn()
			.mockResolvedValueOnce(jsonResponse(200, docResponse, '"s1"'))
			.mockResolvedValueOnce(jsonResponse(200, docResponse, '"s1"'));
		const docA = createFacetClient({
			baseUrl: BASE,
			auth: staticKey('fct_1'),
			fetchImpl: asFetch(fetchImpl),
			cache: true
		})
			.domain('crm')
			.doctype('Company')
			.doc(DOC_ID);
		const docB = createFacetClient({
			baseUrl: BASE,
			auth: staticKey('fct_2'),
			fetchImpl: asFetch(fetchImpl),
			cache: true
		})
			.domain('crm')
			.doctype('Company')
			.doc(DOC_ID);
		await docA.show();
		await docB.show();
		expect(headersOf(fetchImpl, 1)['if-none-match']).toBeUndefined();
	});

	it('an injected store is used', async () => {
		const store = memoryCache();
		const fetchImpl = vi.fn().mockResolvedValue(jsonResponse(200, envelope, '"v1"'));
		const facet = createFacetClient({
			baseUrl: BASE,
			auth: staticKey('fct_1'),
			fetchImpl: asFetch(fetchImpl),
			cache: store
		});
		await facet.domain('crm').doctype('Company').list();
		expect(store.get(listKey)?.validator).toBe('"v1"');
	});

	it('a cached list page still paginates', async () => {
		const rowA = { data: { name: 'A' }, meta };
		const rowB = { data: { name: 'B' }, meta };
		const fetchImpl = vi
			.fn()
			.mockResolvedValueOnce(
				jsonResponse(200, { data: [rowA], meta: { count: 2, more: true } }, '"p1"')
			)
			.mockResolvedValueOnce(notModified())
			.mockResolvedValueOnce(
				jsonResponse(200, { data: [rowB], meta: { count: 2, more: false } }, '"p2"')
			);
		const facet = createFacetClient({
			baseUrl: BASE,
			auth: staticKey('fct_1'),
			fetchImpl: asFetch(fetchImpl),
			cache: true
		});
		const companies = facet.domain('crm').doctype('Company');
		const first = await companies.list();
		const cached = await companies.list();
		expect(cached.data[0]).toBe(first.data[0]); // served from the store, same row object
		const second = await cached.next();
		expect(callOf(fetchImpl, 2).url.searchParams.get('page')).toBe('2');
		expect(second?.data[0]?.data).toEqual({ name: 'B' });
	});
});
