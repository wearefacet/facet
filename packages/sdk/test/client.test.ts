// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it, vi } from 'vitest';
import { staticKey } from '../src/auth/provider.js';
import { createFacetClient, type FacetClient } from '../src/client.js';
import { DeletedError, NotFoundError } from '../src/errors.js';

const BASE = 'https://facet.example.com';
const COMPANIES = `${BASE}/Api/crm/Company`;
const DOC_ID = '01ABCDEF';

function jsonResponse(status: number, body: unknown, statusText = ''): Response {
	return {
		ok: status >= 200 && status < 300,
		status,
		statusText,
		text: async () => JSON.stringify(body)
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

function lastCall(mock: ReturnType<typeof vi.fn>): { url: URL; init: RequestInit } {
	return callOf(mock, mock.mock.calls.length - 1);
}

function bodyOf(init: RequestInit): unknown {
	return JSON.parse(String(init.body));
}

function makeClient(mock: ReturnType<typeof vi.fn>): FacetClient {
	return createFacetClient({ baseUrl: BASE, auth: staticKey('fct_key'), fetchImpl: asFetch(mock) });
}

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

describe('collection handle — routes and verbs', () => {
	it('list hits GET /Api/:domain/:doctype with the bearer header', async () => {
		const fetchImpl = vi
			.fn()
			.mockResolvedValue(jsonResponse(200, { data: [], meta: { count: 0, more: false } }));
		const companies = makeClient(fetchImpl).domain('crm').doctype('Company');
		await companies.list();
		const { url, init } = lastCall(fetchImpl);
		expect(String(url)).toBe(COMPANIES);
		expect(init.method).toBe('GET');
		expect((init.headers as Record<string, string>)['authorization']).toBe('Bearer fct_key');
	});

	it('list serializes params into the query string', async () => {
		const fetchImpl = vi
			.fn()
			.mockResolvedValue(jsonResponse(200, { data: [], meta: { count: 0, more: false } }));
		const companies = makeClient(fetchImpl).domain('crm').doctype('Company');
		await companies.list({
			page: 2,
			items: 50,
			filters: { status__eq: 'active' },
			sort: ['-updated_at'],
			select: ['name', 'status'],
			includeDeleted: true
		});
		const params = lastCall(fetchImpl).url.searchParams;
		expect(params.get('page')).toBe('2');
		expect(params.get('items')).toBe('50');
		expect(params.get('filters[status__eq]')).toBe('active');
		expect(params.get('sort')).toBe('-updated_at');
		expect(params.get('select')).toBe('name,status');
		expect(params.get('deleted')).toBe('true');
	});

	it('create hits POST /Api/:domain/:doctype with the content as the JSON body', async () => {
		const fetchImpl = vi
			.fn()
			.mockResolvedValue(jsonResponse(201, { data: { name: 'Acme' }, meta }));
		const companies = makeClient(fetchImpl).domain('crm').doctype('Company');
		const res = await companies.create({ name: 'Acme' });
		const { url, init } = lastCall(fetchImpl);
		expect(String(url)).toBe(COMPANIES);
		expect(init.method).toBe('POST');
		expect(init.headers).toMatchObject({ 'content-type': 'application/json' });
		expect(bodyOf(init)).toEqual({ name: 'Acme' });
		expect(res.data).toEqual({ name: 'Acme' });
	});

	it('create passes compound-create children through on the response', async () => {
		const child = { data: { event_type: 'hired' }, meta };
		const fetchImpl = vi.fn().mockResolvedValue(
			jsonResponse(201, {
				data: { name: 'Acme' },
				meta,
				children: { career_events: [child] }
			})
		);
		const companies = makeClient(fetchImpl).domain('crm').doctype('Company');
		const res = await companies.create({
			$content: { name: 'Acme' },
			$children: { career_events: [{ event_type: 'hired' }] }
		});
		expect(res.children).toEqual({ career_events: [child] });
	});
});

describe('document ref — routes and verbs', () => {
	it('show hits GET /Api/:domain/:doctype/:id', async () => {
		const fetchImpl = vi
			.fn()
			.mockResolvedValue(jsonResponse(200, { data: { name: 'Acme' }, meta }));
		const doc = makeClient(fetchImpl).domain('crm').doctype('Company').doc(DOC_ID);
		await doc.show();
		const { url, init } = lastCall(fetchImpl);
		expect(String(url)).toBe(`${COMPANIES}/${DOC_ID}`);
		expect(init.method).toBe('GET');
	});

	it('update sends the PATCH diff body as given', async () => {
		const fetchImpl = vi
			.fn()
			.mockResolvedValue(jsonResponse(200, { data: { status: 'archived' }, meta }));
		const doc = makeClient(fetchImpl).domain('crm').doctype('Company').doc(DOC_ID);
		const diff = { status: 'archived', notes: null };
		await doc.update(diff);
		const { url, init } = lastCall(fetchImpl);
		expect(String(url)).toBe(`${COMPANIES}/${DOC_ID}`);
		expect(init.method).toBe('PATCH');
		expect(init.headers).toMatchObject({ 'content-type': 'application/json' });
		expect(bodyOf(init)).toEqual(diff);
	});

	it('delete hits DELETE and resolves on 204', async () => {
		const fetchImpl = vi.fn().mockResolvedValue(jsonResponse(204, undefined));
		const doc = makeClient(fetchImpl).domain('crm').doctype('Company').doc(DOC_ID);
		await expect(doc.delete()).resolves.toBeUndefined();
		const { url, init } = lastCall(fetchImpl);
		expect(String(url)).toBe(`${COMPANIES}/${DOC_ID}`);
		expect(init.method).toBe('DELETE');
	});

	it('action posts to /:id/:name with the args body', async () => {
		const fetchImpl = vi.fn().mockResolvedValue(jsonResponse(200, { data: {}, meta }));
		const doc = makeClient(fetchImpl).domain('crm').doctype('Company').doc(DOC_ID);
		await doc.action('archive', { reason: 'done' });
		const { url, init } = lastCall(fetchImpl);
		expect(String(url)).toBe(`${COMPANIES}/${DOC_ID}/archive`);
		expect(init.method).toBe('POST');
		expect(bodyOf(init)).toEqual({ reason: 'done' });
	});

	it('action without args sends an empty object body', async () => {
		const fetchImpl = vi.fn().mockResolvedValue(jsonResponse(200, { data: {}, meta }));
		const doc = makeClient(fetchImpl).domain('crm').doctype('Company').doc(DOC_ID);
		await doc.action('archive');
		expect(bodyOf(lastCall(fetchImpl).init)).toEqual({});
	});

	it('history hits GET /:id/history with the query parameters', async () => {
		const fetchImpl = vi
			.fn()
			.mockResolvedValue(jsonResponse(200, { data: [], meta: { count: 0, more: false } }));
		const doc = makeClient(fetchImpl).domain('crm').doctype('Company').doc(DOC_ID);
		await doc.history({
			page: 2,
			items: 10,
			sort: ['-idx'],
			include: 'children',
			filters: { action__eq: 'update' }
		});
		const { url, init } = lastCall(fetchImpl);
		expect(url.pathname).toBe(`/Api/crm/Company/${DOC_ID}/history`);
		expect(init.method).toBe('GET');
		const params = url.searchParams;
		expect(params.get('page')).toBe('2');
		expect(params.get('items')).toBe('10');
		expect(params.get('sort')).toBe('-idx');
		expect(params.get('include')).toBe('children');
		expect(params.get('filters[action__eq]')).toBe('update');
	});

	it('history without params sends no query string', async () => {
		const fetchImpl = vi
			.fn()
			.mockResolvedValue(jsonResponse(200, { data: [], meta: { count: 0, more: false } }));
		const doc = makeClient(fetchImpl).domain('crm').doctype('Company').doc(DOC_ID);
		await doc.history();
		expect(String(lastCall(fetchImpl).url)).toBe(`${COMPANIES}/${DOC_ID}/history`);
	});

	it('rollback posts to /:id/rollback with the mutation id', async () => {
		const fetchImpl = vi.fn().mockResolvedValue(
			jsonResponse(200, {
				id: DOC_ID,
				domain: 'crm',
				doc_type: 'Company',
				mut_id: '01JNEW',
				content: {},
				created_at: '2026-01-01T00:00:00Z'
			})
		);
		const doc = makeClient(fetchImpl).domain('crm').doctype('Company').doc(DOC_ID);
		await doc.rollback('01JOLD');
		const { url, init } = lastCall(fetchImpl);
		expect(String(url)).toBe(`${COMPANIES}/${DOC_ID}/rollback`);
		expect(init.method).toBe('POST');
		expect(bodyOf(init)).toEqual({ mutation_id: '01JOLD' });
	});

	it('restore posts to /:id/restore with an empty body', async () => {
		const fetchImpl = vi.fn().mockResolvedValue(
			jsonResponse(200, {
				id: DOC_ID,
				domain: 'crm',
				doc_type: 'Company',
				mut_id: '01JNEW',
				content: {},
				created_at: '2026-01-01T00:00:00Z'
			})
		);
		const doc = makeClient(fetchImpl).domain('crm').doctype('Company').doc(DOC_ID);
		await doc.restore();
		const { url, init } = lastCall(fetchImpl);
		expect(String(url)).toBe(`${COMPANIES}/${DOC_ID}/restore`);
		expect(init.method).toBe('POST');
		expect(bodyOf(init)).toEqual({});
	});

	it('backrefs hits GET /:id/backrefs with the items cap', async () => {
		const fetchImpl = vi.fn().mockResolvedValue(
			jsonResponse(200, {
				data: [],
				meta: { target: `urn:facet:crm:Company:${DOC_ID}`, total: 0, capped: false }
			})
		);
		const doc = makeClient(fetchImpl).domain('crm').doctype('Company').doc(DOC_ID);
		await doc.backrefs({ items: 25 });
		const { url, init } = lastCall(fetchImpl);
		expect(url.pathname).toBe(`/Api/crm/Company/${DOC_ID}/backrefs`);
		expect(init.method).toBe('GET');
		expect(url.searchParams.get('items')).toBe('25');
	});

	it('backrefs without params sends no query string', async () => {
		const fetchImpl = vi.fn().mockResolvedValue(
			jsonResponse(200, {
				data: [],
				meta: { target: `urn:facet:crm:Company:${DOC_ID}`, total: 0, capped: false }
			})
		);
		const doc = makeClient(fetchImpl).domain('crm').doctype('Company').doc(DOC_ID);
		await doc.backrefs();
		expect(String(lastCall(fetchImpl).url)).toBe(`${COMPANIES}/${DOC_ID}/backrefs`);
	});
});

describe('children and sidecars', () => {
	it('children(rel) lists and creates under /:id/:rel', async () => {
		const fetchImpl = vi
			.fn()
			.mockResolvedValue(jsonResponse(200, { data: [], meta: { count: 0, more: false } }));
		const contacts = makeClient(fetchImpl)
			.domain('crm')
			.doctype('Company')
			.doc(DOC_ID)
			.children('contacts');
		await contacts.list();
		let { url, init } = lastCall(fetchImpl);
		expect(String(url)).toBe(`${COMPANIES}/${DOC_ID}/contacts`);
		expect(init.method).toBe('GET');

		vi.mocked(fetchImpl).mockResolvedValue(jsonResponse(201, { data: { name: 'Bob' }, meta }));
		await contacts.create({ name: 'Bob' });
		({ url, init } = lastCall(fetchImpl));
		expect(String(url)).toBe(`${COMPANIES}/${DOC_ID}/contacts`);
		expect(init.method).toBe('POST');
	});

	it('a child ref targets /:id/:rel/:child_id for show, update, and delete', async () => {
		const fetchImpl = vi.fn().mockResolvedValue(jsonResponse(200, { data: {}, meta }));
		const child = makeClient(fetchImpl)
			.domain('crm')
			.doctype('Company')
			.doc(DOC_ID)
			.children('contacts')
			.doc('C1');
		await child.show();
		expect(String(lastCall(fetchImpl).url)).toBe(`${COMPANIES}/${DOC_ID}/contacts/C1`);

		await child.update({ name: 'Bobby' });
		expect(lastCall(fetchImpl).init.method).toBe('PATCH');
		expect(String(lastCall(fetchImpl).url)).toBe(`${COMPANIES}/${DOC_ID}/contacts/C1`);

		await child.delete();
		expect(lastCall(fetchImpl).init.method).toBe('DELETE');
		expect(String(lastCall(fetchImpl).url)).toBe(`${COMPANIES}/${DOC_ID}/contacts/C1`);
	});

	it('a grandchild collection rides the full nested path', async () => {
		const fetchImpl = vi
			.fn()
			.mockResolvedValue(jsonResponse(200, { data: [], meta: { count: 0, more: false } }));
		const notes = makeClient(fetchImpl)
			.domain('crm')
			.doctype('Company')
			.doc(DOC_ID)
			.children('contacts')
			.doc('C1')
			.children('notes');
		await notes.list();
		expect(String(lastCall(fetchImpl).url)).toBe(`${COMPANIES}/${DOC_ID}/contacts/C1/notes`);
	});

	it('sidecars(segment) lists under /:id/:segment', async () => {
		const fetchImpl = vi
			.fn()
			.mockResolvedValue(jsonResponse(200, { data: [], meta: { count: 0, more: false } }));
		const comments = makeClient(fetchImpl)
			.domain('crm')
			.doctype('Company')
			.doc(DOC_ID)
			.sidecars('comments');
		await comments.list();
		const { url, init } = lastCall(fetchImpl);
		expect(String(url)).toBe(`${COMPANIES}/${DOC_ID}/comments`);
		expect(init.method).toBe('GET');
	});
});

describe('pagination — next()', () => {
	it('advances the page while meta.more is true', async () => {
		const fetchImpl = vi
			.fn()
			.mockResolvedValueOnce(
				jsonResponse(200, {
					data: [{ data: { name: 'A' }, meta }],
					meta: { count: 50, more: true }
				})
			)
			.mockResolvedValueOnce(
				jsonResponse(200, {
					data: [{ data: { name: 'B' }, meta }],
					meta: { count: 75, more: false }
				})
			);
		const companies = makeClient(fetchImpl).domain('crm').doctype('Company');

		const first = await companies.list({ items: 50 });
		expect(lastCall(fetchImpl).url.searchParams.get('page')).toBeNull();

		const second = await first.next();
		expect(second).not.toBeNull();
		expect(lastCall(fetchImpl).url.searchParams.get('page')).toBe('2');
		expect(second?.data[0]?.data).toEqual({ name: 'B' });

		const third = await second?.next();
		expect(third).toBeNull();
		expect(fetchImpl).toHaveBeenCalledTimes(2);
	});

	it('walks forward from an explicit page', async () => {
		const fetchImpl = vi
			.fn()
			.mockResolvedValueOnce(jsonResponse(200, { data: [], meta: { count: 150, more: true } }))
			.mockResolvedValueOnce(jsonResponse(200, { data: [], meta: { count: 150, more: false } }));
		const companies = makeClient(fetchImpl).domain('crm').doctype('Company');

		const third = await companies.list({ page: 3, items: 50 });
		expect(lastCall(fetchImpl).url.searchParams.get('page')).toBe('3');

		const fourth = await third.next();
		expect(lastCall(fetchImpl).url.searchParams.get('page')).toBe('4');
		expect(fourth?.meta.more).toBe(false);
		expect(await fourth?.next()).toBeNull();
		expect(fetchImpl).toHaveBeenCalledTimes(2);
	});

	it('returns null without a call when meta.more is false', async () => {
		const fetchImpl = vi
			.fn()
			.mockResolvedValue(jsonResponse(200, { data: [], meta: { count: 5, more: false } }));
		const companies = makeClient(fetchImpl).domain('crm').doctype('Company');
		const page = await companies.list();
		expect(await page.next()).toBeNull();
		expect(fetchImpl).toHaveBeenCalledTimes(1);
	});

	it('returns null for an aggregate call, even when more is true', async () => {
		const fetchImpl = vi
			.fn()
			.mockResolvedValue(jsonResponse(200, { data: [], meta: { count: 1000, more: true } }));
		const companies = makeClient(fetchImpl).domain('crm').doctype('Company');
		const page = await companies.list({ aggregate: 'count', filters: { status__eq: 'active' } });
		expect(lastCall(fetchImpl).url.searchParams.get('aggregate')).toBe('count');
		expect(await page.next()).toBeNull();
		expect(fetchImpl).toHaveBeenCalledTimes(1);
	});
});

describe('error mapping', () => {
	it('maps 404 to NotFoundError', async () => {
		const fetchImpl = vi
			.fn()
			.mockResolvedValue(jsonResponse(404, { error: 'not_found' }, 'Not Found'));
		const doc = makeClient(fetchImpl).domain('crm').doctype('Company').doc(DOC_ID);
		const error = await doc.show().catch((e: unknown) => e);
		expect(error).toBeInstanceOf(NotFoundError);
		expect((error as NotFoundError).status).toBe(404);
	});

	it('maps the 410 tombstone body to DeletedError with meta filled', async () => {
		const fetchImpl = vi.fn().mockResolvedValue(
			jsonResponse(410, {
				error: 'Document deleted',
				display_name: 'Acme Corp',
				deleted_at: '2026-01-01T12:00:00Z'
			})
		);
		const doc = makeClient(fetchImpl).domain('crm').doctype('Company').doc(DOC_ID);
		const error = await doc.show().catch((e: unknown) => e);
		expect(error).toBeInstanceOf(DeletedError);
		const deleted = error as DeletedError;
		expect(deleted.status).toBe(410);
		expect(deleted.displayName).toBe('Acme Corp');
		expect(deleted.deletedAt).toBe('2026-01-01T12:00:00Z');
		expect(deleted.meta['display_name']).toBe('Acme Corp');
	});
});
