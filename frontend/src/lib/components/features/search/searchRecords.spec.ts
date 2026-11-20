// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import {
	buildSearchUrl,
	createRecordSearch,
	shapeSearchResponse,
	setRecordSearchTransport,
	SEARCH_DEBOUNCE_MS,
	SEARCH_MIN_QUERY_LENGTH,
	type SearchResponse,
	type RecordEntry
} from './searchRecords.js';

/** A fixture response shaped like the backend contract (doc/backend/search.md
 *  → Contract): `domain`/`doctype` ride the group, never the hit. */
function fixtureResponse(overrides?: Partial<SearchResponse>): SearchResponse {
	return {
		data: [
			{
				domain: 'crm',
				doctype: 'Company',
				hits: [
					{
						id: 'crm.Company.1',
						display_name: 'Acme Corp',
						rank: 0.9,
						root_doctype: 'Company',
						root_id: 'crm.Company.1',
						root_display_name: 'Acme Corp',
						child_label: null
					}
				]
			},
			{
				domain: 'hr',
				doctype: 'Employee',
				hits: [
					{
						id: 'hr.Employee.7',
						display_name: 'Alice',
						rank: 0.8,
						root_doctype: 'Employee',
						root_id: 'hr.Employee.7',
						root_display_name: 'Alice',
						child_label: null
					}
				]
			}
		],
		meta: { q: 'acme', count: 2, scope: 'domain' },
		...overrides
	};
}

interface TransportCall {
	url: string;
}

function stubTransport(responder: (url: string) => Response): {
	fn: typeof fetch;
	calls: TransportCall[];
} {
	const calls: TransportCall[] = [];
	const fn = vi.fn(async (input: string | URL | Request) => {
		const url = typeof input === 'string' ? input : input.toString();
		calls.push({ url });
		return responder(url);
	}) as unknown as typeof fetch;
	return { fn, calls };
}

describe('buildSearchUrl', () => {
	it('routes the domain scope through the active domain', () => {
		expect(buildSearchUrl('acme', 'domain', 'crm')).toBe('/Api/crm/search?q=acme');
	});

	it('routes the app scope past any domain', () => {
		expect(buildSearchUrl('acme', 'app', 'crm')).toBe('/Api/search?q=acme');
	});

	it('URL-encodes the term', () => {
		expect(buildSearchUrl('health potion', 'domain', 'ops')).toBe(
			`/Api/ops/search?q=${encodeURIComponent('health potion')}`
		);
	});
});

describe('shapeSearchResponse', () => {
	it('flattens groups into one entry per root hit', () => {
		const entries = shapeSearchResponse(fixtureResponse(), 'crm');
		expect(entries).toHaveLength(2);
		expect(entries[0]).toMatchObject({
			key: 'crm.Company.crm.Company.1',
			domain: 'crm',
			doctype: 'Company',
			id: 'crm.Company.1',
			label: 'Acme Corp',
			subtitle: null
		});
		expect(entries[1]?.label).toBe('Alice');
	});

	it('collapses child hits into one entry per root, subtitle from the top-ranked child', () => {
		const resp = fixtureResponse();
		resp.data = [
			{
				domain: 'crm',
				doctype: 'CompanyMembership',
				hits: [
					{
						id: 'crm.CompanyMembership.2',
						display_name: 'Bronze plan',
						rank: 0.7,
						root_doctype: 'Company',
						root_id: 'crm.Company.1',
						root_display_name: 'Acme Corp',
						child_label: 'Bronze plan'
					},
					{
						id: 'crm.CompanyMembership.3',
						display_name: 'Silver plan',
						rank: 0.6,
						root_doctype: 'Company',
						root_id: 'crm.Company.1',
						root_display_name: 'Acme Corp',
						child_label: 'Silver plan'
					}
				]
			}
		];
		const entries = shapeSearchResponse(resp, 'crm');
		expect(entries).toHaveLength(1);
		expect(entries[0]?.label).toBe('Acme Corp');
		// The first child hit in rank order wins the subtitle slot.
		expect(entries[0]?.subtitle).toBe('CompanyMembership · Bronze plan');
		expect(entries[0]?.id).toBe('crm.Company.1');
	});

	it('keeps the server rank order within a scope', () => {
		const entries = shapeSearchResponse(fixtureResponse(), 'crm');
		expect(entries.map((e) => e.label)).toEqual(['Acme Corp', 'Alice']);
	});

	it('leads with the active domain when the scope is app-wide, keeping rank order otherwise', () => {
		const entries = shapeSearchResponse(fixtureResponse(), 'hr');
		expect(entries.map((e) => e.domain)).toEqual(['hr', 'crm']);
		expect(entries.map((e) => e.label)).toEqual(['Alice', 'Acme Corp']);
	});

	it('does not reorder when every group belongs to the active domain', () => {
		const entries = shapeSearchResponse(fixtureResponse(), 'crm');
		expect(entries.map((e) => e.domain)).toEqual(['crm', 'hr']);
	});

	it('inherits the group domain and doctype on every entry (B-119)', () => {
		// The wire contract carries `domain`/`doctype` at group level only —
		// the palette row needs them per entry to resolve its show-page route.
		const resp = fixtureResponse();
		const entries = shapeSearchResponse(resp, 'crm');
		expect(entries.map((e) => [e.domain, e.doctype])).toEqual([
			['crm', 'Company'],
			['hr', 'Employee']
		]);
	});

	it('drops a group whose domain is missing or malformed, keeping the rest (B-119)', () => {
		// A group without a usable domain cannot anchor a row to a page the
		// app can open — shaping degrades by dropping it, never by throwing.
		const resp = fixtureResponse({ meta: { q: 'acme', count: 3, scope: 'domain' } });
		resp.data = [
			{ doctype: 'Company', hits: [{ ...resp.data![0]!.hits[0]! }] },
			{ domain: 42, doctype: 'Company', hits: [{ ...resp.data![0]!.hits[0]! }] },
			resp.data![1]!
		] as unknown as SearchResponse['data'];
		const entries = shapeSearchResponse(resp, 'crm');
		expect(entries).toHaveLength(1);
		expect(entries[0]).toMatchObject({
			domain: 'hr',
			doctype: 'Employee',
			id: 'hr.Employee.7',
			label: 'Alice'
		});
	});
});

describe('createRecordSearch', () => {
	beforeEach(() => {
		vi.useFakeTimers();
	});

	afterEach(() => {
		vi.useRealTimers();
		setRecordSearchTransport(null);
	});

	function makeSearch(onResults: (entries: ReturnType<typeof shapeSearchResponse>) => void) {
		return createRecordSearch({ onResults });
	}

	/** Drains the microtask queue — a resolved transport response still has
	 *  several awaits to walk through before the handler runs. */
	async function flush(): Promise<void> {
		for (let i = 0; i < 20; i++) await Promise.resolve();
	}

	it('gates on the minimum query length and clears stale rows', async () => {
		const { fn, calls } = stubTransport(() => new Response(JSON.stringify(fixtureResponse())));
		setRecordSearchTransport(fn);
		const seen: RecordEntry[][] = [];
		const search = makeSearch((entries) => seen.push(entries));

		search.query('a', 'domain', 'crm');
		await vi.advanceTimersByTimeAsync(SEARCH_DEBOUNCE_MS * 2);
		expect(calls).toHaveLength(0);
		// A short query clears the group at once — no stale rows linger.
		expect(seen.at(-1)).toEqual([]);

		search.query('acme', 'domain', 'crm');
		await vi.advanceTimersByTimeAsync(SEARCH_DEBOUNCE_MS + 50);
		expect(calls).toHaveLength(1);
	});

	it('fires one request per debounced burst', async () => {
		const { fn, calls } = stubTransport(() => new Response(JSON.stringify(fixtureResponse())));
		setRecordSearchTransport(fn);
		const search = makeSearch(() => {});

		search.query('acm', 'domain', 'crm');
		await vi.advanceTimersByTimeAsync(50);
		search.query('acme', 'domain', 'crm');
		await vi.advanceTimersByTimeAsync(50);
		search.query('acme ', 'domain', 'crm');
		await vi.advanceTimersByTimeAsync(SEARCH_DEBOUNCE_MS + 50);

		expect(calls).toHaveLength(1);
		// The burst coalesces to the last trimmed term.
		expect(calls[0]?.url).toBe('/Api/crm/search?q=acme');
	});

	it('delivers the shaped rows to the handler', async () => {
		const { fn } = stubTransport(() => new Response(JSON.stringify(fixtureResponse())));
		setRecordSearchTransport(fn);
		const seen: RecordEntry[][] = [];
		const search = makeSearch((entries) => seen.push(entries));

		search.query('acme', 'domain', 'crm');
		await vi.advanceTimersByTimeAsync(SEARCH_DEBOUNCE_MS + 50);
		expect(seen.at(-1)?.[0]).toMatchObject({ label: 'Acme Corp', subtitle: null });
	});

	it('drops a stale response that lands out of order', async () => {
		// Each request's response is held until the test releases it, so the
		// arrival order is under the test's control.
		const pending: Array<(resp: Response) => void> = [];
		const gatedFetch = (async (input: string | URL | Request) => {
			void input;
			return new Promise<Response>((resolve) => pending.push(resolve));
		}) as unknown as typeof fetch;
		setRecordSearchTransport(gatedFetch);

		const seen: RecordEntry[][] = [];
		const search = makeSearch((entries) => seen.push(entries));

		search.query('first', 'domain', 'crm');
		await vi.advanceTimersByTimeAsync(SEARCH_DEBOUNCE_MS + 10);
		expect(pending).toHaveLength(1);

		// A second burst supersedes the in-flight first request.
		search.query('second', 'domain', 'crm');
		await vi.advanceTimersByTimeAsync(SEARCH_DEBOUNCE_MS + 10);
		expect(pending).toHaveLength(2);

		// The stale response lands first — it must not write.
		pending[0]?.(
			new Response(
				JSON.stringify(fixtureResponse({ meta: { q: 'first', count: 1, scope: 'domain' } }))
			)
		);
		await flush();
		expect(seen).toHaveLength(0);

		// The fresh response writes.
		pending[1]?.(
			new Response(
				JSON.stringify(fixtureResponse({ meta: { q: 'second', count: 1, scope: 'domain' } }))
			)
		);
		await flush();
		expect(seen).toHaveLength(1);
	});

	it('switches scope between the domain and the app route', async () => {
		const { fn, calls } = stubTransport(() => new Response(JSON.stringify(fixtureResponse())));
		setRecordSearchTransport(fn);
		const search = makeSearch(() => {});

		search.query('acme', 'domain', 'crm');
		await vi.advanceTimersByTimeAsync(SEARCH_DEBOUNCE_MS + 10);
		search.query('acme', 'app', 'crm');
		await vi.advanceTimersByTimeAsync(SEARCH_DEBOUNCE_MS + 10);
		search.query('acme', 'domain', 'crm');
		await vi.advanceTimersByTimeAsync(SEARCH_DEBOUNCE_MS + 10);

		expect(calls.map((c) => c.url)).toEqual([
			'/Api/crm/search?q=acme',
			'/Api/search?q=acme',
			'/Api/crm/search?q=acme'
		]);
	});

	it('drops the records group silently when the request fails', async () => {
		const { fn } = stubTransport(() => new Response(null, { status: 500 }));
		setRecordSearchTransport(fn);
		const seen: RecordEntry[][] = [];
		const search = makeSearch((entries) => seen.push(entries));

		search.query('acme', 'domain', 'crm');
		await vi.advanceTimersByTimeAsync(SEARCH_DEBOUNCE_MS + 50);
		expect(seen.at(-1)).toEqual([]);
	});

	it('drops the records group silently when the transport throws', async () => {
		const fn = vi.fn(async () => {
			throw new Error('network down');
		}) as unknown as typeof fetch;
		setRecordSearchTransport(fn);
		const seen: RecordEntry[][] = [];
		const search = makeSearch((entries) => seen.push(entries));

		search.query('acme', 'domain', 'crm');
		await vi.advanceTimersByTimeAsync(SEARCH_DEBOUNCE_MS + 50);
		expect(seen.at(-1)).toEqual([]);
	});

	it('drops a non-2xx response without throwing', async () => {
		const { fn } = stubTransport(
			() => new Response(JSON.stringify({ error: 'nope' }), { status: 403 })
		);
		setRecordSearchTransport(fn);
		const seen: RecordEntry[][] = [];
		const search = makeSearch((entries) => seen.push(entries));

		search.query('acme', 'domain', 'crm');
		await vi.advanceTimersByTimeAsync(SEARCH_DEBOUNCE_MS + 50);
		expect(seen.at(-1)).toEqual([]);
	});

	it('reset() cancels the pending burst and clears the rows', async () => {
		const { fn, calls } = stubTransport(() => new Response(JSON.stringify(fixtureResponse())));
		setRecordSearchTransport(fn);
		const seen: RecordEntry[][] = [];
		const search = makeSearch((entries) => seen.push(entries));

		search.query('acme', 'domain', 'crm');
		search.reset();
		await vi.advanceTimersByTimeAsync(SEARCH_DEBOUNCE_MS * 2);
		expect(calls).toHaveLength(0);
		expect(seen.at(-1)).toEqual([]);
	});

	it('honours a handler-level transport over the module seam', async () => {
		const seam = stubTransport(() => new Response(JSON.stringify(fixtureResponse())));
		const local = stubTransport(
			() =>
				new Response(
					JSON.stringify(
						fixtureResponse({ data: [], meta: { q: 'acme', count: 0, scope: 'domain' } })
					)
				)
		);
		setRecordSearchTransport(seam.fn);
		const seen: RecordEntry[][] = [];
		const search = createRecordSearch({ onResults: (e) => seen.push(e), transport: local.fn });

		search.query('acme', 'domain', 'crm');
		await vi.advanceTimersByTimeAsync(SEARCH_DEBOUNCE_MS + 50);
		expect(local.calls).toHaveLength(1);
		expect(seam.calls).toHaveLength(0);
	});
});

describe('contract guards', () => {
	it('exports the ruled constants', () => {
		expect(SEARCH_MIN_QUERY_LENGTH).toBe(2);
		expect(SEARCH_DEBOUNCE_MS).toBe(250);
	});
});
