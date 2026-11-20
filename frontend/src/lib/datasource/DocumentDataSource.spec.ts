// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { DocumentDataDriver } from './DocumentDriver.js';
import { MockDataDriver } from './MockDriver.js';
import { MockDataSource } from './MockDataSource.js';
import { DataSourceError } from './types.js';

/**
 * Regression tests for the bug where a `fetchFn` passed to `DocumentDataDriver`
 * bypassed `apiFetch` entirely — skipping pre-emptive token refresh and 401
 * recovery. The fix forwards `fetchFn` to `apiFetch` as `opts.fetch`.
 *
 * These tests use the real `apiFetch` (no mock); they stub the network layer
 * (the injected `fetchFn`) and assert on the calls it receives.
 */

interface FetchCall {
	url: string;
	init?: RequestInit;
}

function makeFetchCapture(log: FetchCall[]) {
	const calls: FetchCall[] = log;
	const fn = vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
		const url = typeof input === 'string' ? input : input.toString();
		calls.push({ url, init });
		return new Response(JSON.stringify({ error: 'not stubbed' }), {
			status: 404,
			headers: { 'Content-Type': 'application/json' }
		});
	});
	return fn;
}

function jsonResponse(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'Content-Type': 'application/json' }
	});
}

const REFRESH_URL = '/Api/iam/refresh';

describe('DocumentDataSource — URL construction (regression: children() double-append)', () => {
	interface FetchCall {
		url: string;
		init?: RequestInit;
	}

	function captureFetch(log: FetchCall[]): typeof fetch {
		return vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
			const url = typeof input === 'string' ? input : input.toString();
			log.push({ url, init });
			return new Response(JSON.stringify({ data: [], meta: { count: 0, more: false } }), {
				status: 200,
				headers: { 'Content-Type': 'application/json' }
			});
		});
	}

	it('children(rel).list() hits <parent>/rel (no doubled segment)', async () => {
		const calls: FetchCall[] = [];
		const driver = new DocumentDataDriver('', captureFetch(calls));
		await driver
			.domain('core')
			.doctype('DocType')
			.doc('iam.LoginEvent')
			.children('collection_view')
			.list({ items: 25 });

		const url = calls.at(-1)?.url ?? '';
		expect(url.startsWith('/Api/core/DocType/iam.LoginEvent/collection_view')).toBe(true);
		expect(url).not.toContain('collection_view/collection_view');
	});

	it('children(rel).create() POSTs to <parent>/rel', async () => {
		const calls: FetchCall[] = [];
		const driver = new DocumentDataDriver('', captureFetch(calls));
		await driver
			.domain('core')
			.doctype('DocType')
			.doc('iam.LoginEvent')
			.children('collection_view')
			.create({ name: 'All', surface: 'table' });

		const call = calls.at(-1);
		expect(call?.init?.method).toBe('POST');
		expect(call?.url).toBe('/Api/core/DocType/iam.LoginEvent/collection_view');
	});

	it('children(rel).doc(id).show() GETs <parent>/rel/<id>', async () => {
		const calls: FetchCall[] = [];
		const driver = new DocumentDataDriver('', captureFetch(calls));
		await driver
			.domain('core')
			.doctype('DocType')
			.doc('iam.LoginEvent')
			.children('collection_view')
			.doc('v01XYZ')
			.show();

		const call = calls.at(-1);
		expect(call?.init?.method ?? 'GET').toBe('GET');
		expect(call?.url).toBe('/Api/core/DocType/iam.LoginEvent/collection_view/v01XYZ');
	});

	it('list() with aggregate=count appends the query parameter', async () => {
		const calls: FetchCall[] = [];
		const driver = new DocumentDataDriver('', captureFetch(calls));
		await driver
			.domain('crm')
			.doctype('Company')
			.list({
				aggregate: 'count',
				filters: { status__eq: 'active' }
			});
		const url = new URL(calls.at(-1)!.url, 'http://test');
		expect(url.searchParams.get('aggregate')).toBe('count');
		expect(url.searchParams.get('filters[status__eq]')).toBe('active');
	});

	it('list() JSON-encodes an array filter value (money __between lanes)', async () => {
		// `String(array)` flattens to a comma-joined string the backend cannot
		// parse — a kanban `__between` lane silently matched nothing. Arrays
		// ride JSON-encoded; the backend decodes them back into an array.
		const calls: FetchCall[] = [];
		const driver = new DocumentDataDriver('', captureFetch(calls));
		await driver
			.domain('crm')
			.doctype('Deal')
			.list({
				filters: { value__between: ['USD 25000', 'USD 100000'] }
			});
		const url = new URL(calls.at(-1)!.url, 'http://test');
		expect(url.searchParams.get('filters[value__between]')).toBe(
			JSON.stringify(['USD 25000', 'USD 100000'])
		);
	});
});

describe('DocumentDataSource — sidecars() URL shapes', () => {
	interface FetchCall {
		url: string;
		init?: RequestInit;
	}

	function captureFetch(log: FetchCall[]): typeof fetch {
		return vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
			const url = typeof input === 'string' ? input : input.toString();
			log.push({ url, init });
			return new Response(JSON.stringify({ data: [], meta: { count: 0, more: false } }), {
				status: 200,
				headers: { 'Content-Type': 'application/json' }
			});
		});
	}

	// Sidecar routes are URL-identical to child per-doc routes
	// (`/Api/:domain/:doctype/:id/:segment`); these specs pin that shape so a
	// refactor cannot silently diverge the two accessors.

	it('sidecars(seg).list() GETs <parent>/seg', async () => {
		const calls: FetchCall[] = [];
		const driver = new DocumentDataDriver('', captureFetch(calls));
		await driver.domain('crm').doctype('Deal').doc('crm.Deal.1').sidecars('comments').list();

		const call = calls.at(-1);
		expect(call?.init?.method ?? 'GET').toBe('GET');
		expect(call?.url).toBe('/Api/crm/Deal/crm.Deal.1/comments');
	});

	it('sidecars(seg).create() POSTs to <parent>/seg', async () => {
		const calls: FetchCall[] = [];
		const driver = new DocumentDataDriver('', captureFetch(calls));
		await driver
			.domain('crm')
			.doctype('Deal')
			.doc('crm.Deal.1')
			.sidecars('comments')
			.create({ body: 'hello', author: 'iam.Account.account_x' });

		const call = calls.at(-1);
		expect(call?.init?.method).toBe('POST');
		expect(call?.url).toBe('/Api/crm/Deal/crm.Deal.1/comments');
	});

	it('sidecars(seg).doc(id).show() GETs <parent>/seg/<id>', async () => {
		const calls: FetchCall[] = [];
		const driver = new DocumentDataDriver('', captureFetch(calls));
		await driver
			.domain('crm')
			.doctype('Deal')
			.doc('crm.Deal.1')
			.sidecars('comments')
			.doc('comment-show-1')
			.show();

		const call = calls.at(-1);
		expect(call?.init?.method ?? 'GET').toBe('GET');
		expect(call?.url).toBe('/Api/crm/Deal/crm.Deal.1/comments/comment-show-1');
	});

	it('sidecars(seg).doc(id).update() PATCHes <parent>/seg/<id>', async () => {
		const calls: FetchCall[] = [];
		const driver = new DocumentDataDriver('', captureFetch(calls));
		await driver
			.domain('crm')
			.doctype('Deal')
			.doc('crm.Deal.1')
			.sidecars('comments')
			.doc('comment-update-1')
			.update({ body: 'edited' });

		const call = calls.at(-1);
		expect(call?.init?.method).toBe('PATCH');
		expect(call?.url).toBe('/Api/crm/Deal/crm.Deal.1/comments/comment-update-1');
	});

	it('sidecars(seg).doc(id).delete() DELETEs <parent>/seg/<id>', async () => {
		const calls: FetchCall[] = [];
		const driver = new DocumentDataDriver('', captureFetch(calls));
		await driver
			.domain('crm')
			.doctype('Deal')
			.doc('crm.Deal.1')
			.sidecars('comments')
			.doc('comment-delete-1')
			.delete();

		const call = calls.at(-1);
		expect(call?.init?.method).toBe('DELETE');
		expect(call?.url).toBe('/Api/crm/Deal/crm.Deal.1/comments/comment-delete-1');
	});
});

describe('DocumentDataSource — backrefs() URL shapes', () => {
	interface FetchCall {
		url: string;
		init?: RequestInit;
	}

	function captureFetch(log: FetchCall[]): typeof fetch {
		return vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
			const url = typeof input === 'string' ? input : input.toString();
			log.push({ url, init });
			return new Response(
				JSON.stringify({
					data: [],
					meta: { target: 'urn:facet:crm:Deal:crm.Deal.1', total: 0, capped: false }
				}),
				{
					status: 200,
					headers: { 'Content-Type': 'application/json' }
				}
			);
		});
	}

	it('backrefs() GETs <parent>/backrefs with the { data, meta: { target, total, capped } } envelope', async () => {
		const calls: FetchCall[] = [];
		const driver = new DocumentDataDriver('', captureFetch(calls));
		const res = await driver.domain('crm').doctype('Deal').doc('crm.Deal.1').backrefs();

		const call = calls.at(-1);
		expect(call?.init?.method ?? 'GET').toBe('GET');
		expect(call?.url).toBe('/Api/crm/Deal/crm.Deal.1/backrefs');
		expect(res.meta.target).toBe('urn:facet:crm:Deal:crm.Deal.1');
		expect(res.meta.capped).toBe(false);
	});

	it('backrefs({ items }) appends the items cap', async () => {
		const calls: FetchCall[] = [];
		const driver = new DocumentDataDriver('', captureFetch(calls));
		await driver.domain('crm').doctype('Deal').doc('crm.Deal.1').backrefs({ items: 25 });

		const url = new URL(calls.at(-1)!.url, 'http://test');
		expect(url.pathname).toBe('/Api/crm/Deal/crm.Deal.1/backrefs');
		expect(url.searchParams.get('items')).toBe('25');
	});

	it('backrefs() surfaces a non-disclosing 404 as DataSourceError', async () => {
		const driver = new DocumentDataDriver(
			'',
			vi.fn(async () => jsonResponse({ error: 'Document crm.Deal.1 not found' }, 404))
		);
		await expect(
			driver.domain('crm').doctype('Deal').doc('crm.Deal.1').backrefs()
		).rejects.toMatchObject({ name: 'DataSourceError', status: 404 });
	});
});

describe('MockDataSource — sidecars', () => {
	// The mock shares one docs map across doctypes; sidecar records of
	// `core.Comment` carry `{ target: "<host qualified ref>" }`. The sidecar
	// collection filters by that reference column pointing at the host —
	// forgiving both the qualified form (`crm.Deal.crm.Deal.1`) and the bare
	// host id (`crm.Deal.1`) that fixtures use.
	function makeDriver(registerDef = true): MockDataDriver {
		const driver = new MockDataDriver();
		if (registerDef) {
			driver.registerDoctype('crm', 'Deal', {
				doctype: 'Deal',
				domain: 'crm',
				sidecar: true,
				sidecars: { comments: { doctype: 'core.Comment', column: 'target' } }
			});
		}
		driver.domain('crm').doctype('Deal', [{ id: 'crm.Deal.1', title: 'Big deal' }]);
		driver.domain('core').doctype('Comment', [
			{ id: 'c1', target: 'crm.Deal.crm.Deal.1', body: 'qualified form' },
			{ id: 'c2', target: 'crm.Deal.1', body: 'bare id form' },
			{ id: 'c3', target: 'crm.Deal.2', body: 'another host' }
		]);
		return driver;
	}

	function sidecarDs(driver: MockDataDriver, segment = 'comments') {
		return driver.domain('crm').doctype('Deal').doc('crm.Deal.1').sidecars(segment);
	}

	it('lists only the host’s comments (both reference forms), not other hosts’', async () => {
		const res = await sidecarDs(makeDriver()).list();
		expect(res.meta.count).toBe(2);
		expect(res.data.map((item) => item.data.body).sort()).toEqual([
			'bare id form',
			'qualified form'
		]);
	});

	it('create() appends a record and sets the reference column on the route’s behalf', async () => {
		const driver = makeDriver();
		const ds = sidecarDs(driver);
		const res = await ds.create({ body: 'hello', author: 'iam.Account.account_x' });
		expect(res.data.target).toBe('crm.Deal.crm.Deal.1');
		expect(res.data.body).toBe('hello');

		const after = await ds.list();
		expect(after.meta.count).toBe(3);
	});

	it('update and delete via .doc(id) work like any other document', async () => {
		const ds = sidecarDs(makeDriver());
		await ds.doc('c1').update({ body: 'edited' });
		const shown = await ds.doc('c1').show();
		expect(shown.data.body).toBe('edited');
		expect(shown.data.target).toBe('crm.Deal.crm.Deal.1');

		await ds.doc('c1').delete();
		const after = await ds.list();
		expect(after.meta.count).toBe(1);
	});

	it('create() with the reference column in the body rejects 400', async () => {
		const ds = sidecarDs(makeDriver());
		const err = await ds.create({ target: 'crm.Deal.crm.Deal.1', body: 'nope' }).then(
			() => null,
			(e) => e
		);
		expect(err).toBeInstanceOf(DataSourceError);
		expect((err as DataSourceError).status).toBe(400);
		expect((err as DataSourceError).message).toBe(
			"The 'target' field is set by the route and must not be supplied in the body"
		);
	});

	it('an unknown segment rejects 404', async () => {
		const err = await sidecarDs(makeDriver(), 'attachments')
			.list()
			.then(
				() => null,
				(e) => e
			);
		expect(err).toBeInstanceOf(DataSourceError);
		expect((err as DataSourceError).status).toBe(404);
		expect((err as DataSourceError).message).toBe("Unknown sidecar 'attachments'");
	});

	it('rejects 404 when the host doctype has no registered definition', async () => {
		const err = await sidecarDs(makeDriver(false))
			.list()
			.then(
				() => null,
				(e) => e
			);
		expect(err).toBeInstanceOf(DataSourceError);
		expect((err as DataSourceError).status).toBe(404);
	});
});

describe('DocumentDataDriver — apiFetch integration (refresh + 401 recovery)', () => {
	beforeEach(() => {
		vi.useFakeTimers();
	});
	afterEach(() => {
		vi.useRealTimers();
	});

	it('refreshes the token and retries on 401 when a fetchFn is provided (the original bug)', async () => {
		let apiCalls = 0;
		let refreshCalls = 0;
		const calls: FetchCall[] = [];

		const fetchFn = async (input: string | URL | Request, init?: RequestInit) => {
			const url = typeof input === 'string' ? input : input.toString();
			calls.push({ url, init });
			if (url === REFRESH_URL) {
				refreshCalls++;
				return jsonResponse({ expires_at: Math.floor(Date.now() / 1000) + 900 });
			}
			if (url.startsWith('/Api/core/DocType')) {
				apiCalls++;
				if (apiCalls === 1) {
					// First call: token expired → 401.
					return jsonResponse({ error: 'token expired' }, 401);
				}
				// Retry after refresh: success.
				return jsonResponse({
					data: [{ data: { domain: 'hr', doctype: 'Employee' }, meta: { id: 'dt1' } }],
					meta: { count: 1, more: false }
				});
			}
			return jsonResponse({ error: 'unexpected' }, 500);
		};

		const driver = new DocumentDataDriver('', fetchFn);
		const result = await driver.domain('core').doctype('DocType').list();

		expect(result.data).toHaveLength(1);
		expect(result.meta.count).toBe(1);
		expect(refreshCalls).toBe(1);
		// Exactly two calls to the doctype endpoint: the 401, then the retry.
		const apiEndpoints = calls.filter((c) => c.url.startsWith('/Api/core/DocType'));
		expect(apiEndpoints).toHaveLength(2);
		// The refresh must happen between the two API calls.
		expect(calls.map((c) => c.url)).toEqual([
			'/Api/core/DocType',
			REFRESH_URL,
			'/Api/core/DocType'
		]);
	});

	it('does NOT retry when attemptRefresh is implicitly true but refresh fails', async () => {
		// When the refresh call itself fails, `apiFetch` returns a 401 Response
		// (or redirects in the browser). The DataSource surfaces this as a
		// `DataSourceError` rather than retrying indefinitely.
		let apiCalls = 0;
		const fetchFn = async (input: string | URL | Request, _init?: RequestInit) => {
			const url = typeof input === 'string' ? input : input.toString();
			if (url === REFRESH_URL) {
				return jsonResponse({ error: 'refresh token invalid' }, 401);
			}
			if (url.startsWith('/Api/core/DocType')) {
				apiCalls++;
				return jsonResponse({ error: 'token expired' }, 401);
			}
			return jsonResponse({}, 404);
		};

		const driver = new DocumentDataDriver('', fetchFn);
		await expect(driver.domain('core').doctype('DocType').list()).rejects.toBeInstanceOf(
			DataSourceError
		);
		// Only one API call — no retry because the refresh failed.
		expect(apiCalls).toBe(1);
	});

	it('forwards the injected fetchFn to apiFetch as opts.fetch (regression: was bypassed)', async () => {
		// Verifies the contract: even though native `fetch` is the default, an
		// injected `fetchFn` is the one actually used for both the API call and
		// the refresh call. This is what makes SSR + auto-refresh work together.
		const calls: FetchCall[] = [];
		const fetchFn = makeFetchCapture(calls);
		// Make the first call succeed outright (no 401) for a clean assertion.
		fetchFn.mockImplementation(async (input, init) => {
			const url = typeof input === 'string' ? input : input.toString();
			calls.push({ url, init });
			if (url.startsWith('/Api/core/DocType')) {
				return jsonResponse({ data: [], meta: { count: 0, more: false } });
			}
			return jsonResponse({}, 404);
		});

		const driver = new DocumentDataDriver('', fetchFn);
		await driver.domain('core').doctype('DocType').list({ items: 500 });

		expect(fetchFn).toHaveBeenCalledTimes(1);
		// The injected fetchFn is used; native `fetch` is never called.
		expect(calls[0].url).toContain('/Api/core/DocType');
		// `items=500` query string should be present (from ListParams).
		expect(calls[0].url).toContain('items=500');
	});
});

describe('MockDataSource — backrefs', () => {
	it('returns the registered rows for a document with the target URN meta', async () => {
		const ds = new MockDataSource('bref', 'Team', [{ id: 't1', name: 'Core' }]);
		ds.onBackrefs('t1', [
			{ id: 'p1', domain: 'bref', doc_type: 'Project', display_name: 'Apollo' },
			{ id: 'n1', domain: 'other', doc_type: 'Note', display_name: null }
		]);

		const res = await ds.doc('t1').backrefs();
		expect(res.data).toEqual([
			{ id: 'p1', domain: 'bref', doc_type: 'Project', display_name: 'Apollo' },
			{ id: 'n1', domain: 'other', doc_type: 'Note', display_name: null }
		]);
		expect(res.meta.target).toBe('urn:facet:bref:Team:t1');
		expect(res.meta.total).toBe(2);
		expect(res.meta.capped).toBe(false);
	});

	it('caps at items and reports capped honestly', async () => {
		const ds = new MockDataSource('bref', 'Team', [{ id: 't1', name: 'Core' }]);
		ds.onBackrefs('t1', [
			{ id: 'p1', domain: 'bref', doc_type: 'Project', display_name: 'A' },
			{ id: 'p2', domain: 'bref', doc_type: 'Project', display_name: 'B' }
		]);

		const res = await ds.doc('t1').backrefs({ items: 1 });
		expect(res.data).toHaveLength(1);
		expect(res.meta.capped).toBe(true);
	});

	it('rejects for an unknown document, like the backend non-disclosing 404', async () => {
		const ds = new MockDataSource('bref', 'Team', [{ id: 't1', name: 'Core' }]);
		await expect(ds.doc('absent').backrefs()).rejects.toThrow('not found');
	});
});
