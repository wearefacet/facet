// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect, vi, afterEach } from 'vitest';
import {
	getCount,
	getCountsVersion,
	loadForDomain,
	clearCounts,
	invalidateCount,
	clearDomainCounts
} from './navCounts.svelte.js';
import type { NavDoctype } from './navTypes';
import type { DataDriver, Domain } from './datasource/driver.js';
import type { DataSource } from './datasource/interface.js';
import type { ListResponse } from './datasource/types.js';

/**
 * Unit tests for the lazy sidebar count store.
 *
 * The store holds `Map<qualified, count>` in module-level `$state`, so each
 * test resets via `clearCounts()` in `afterEach` to prevent cross-test
 * leakage. The driver is a hand-rolled stub rather than `MockDataDriver`
 * because the assertions care about which `doctype(...).list({...})` call
 * the store makes, not about real count semantics.
 */

function makeDriverStub(
	calls: Array<{ domain: string; doctype: string; params: unknown }>,
	countsByQualified: Record<string, number>
): DataDriver {
	const domains = new Map<string, Domain>();
	return {
		getDoctypeDefinition: () => undefined,
		domain: (name: string) => {
			let d = domains.get(name);
			if (!d) {
				d = {
					doctype: (dt: string) => {
						const qualified = `${name}.${dt}`;
						return {
							list: vi.fn(async (params?: { aggregate?: 'count' }) => {
								calls.push({ domain: name, doctype: dt, params: params ?? {} });
								const count = countsByQualified[qualified] ?? 0;
								const response: ListResponse = {
									data: [],
									meta: { count, more: false }
								};
								return response;
							})
						} as unknown as DataSource;
					}
				} as unknown as Domain;
				domains.set(name, d);
			}
			return d;
		}
	};
}

function navDoctype(qualified: string, label: string): NavDoctype {
	return {
		qualified,
		label,
		color: '#000',
		icon: null,
		pinned: false
	};
}

afterEach(() => {
	clearCounts();
});

describe('navCounts', () => {
	it('returns undefined before loadForDomain runs', () => {
		expect(getCount('crm.Company')).toBeUndefined();
	});

	it('resolves counts for the supplied doctypes', async () => {
		const calls: Array<{ domain: string; doctype: string; params: unknown }> = [];
		const driver = makeDriverStub(calls, { 'crm.Company': 7, 'crm.Contact': 3 });
		const doctypes = [navDoctype('crm.Company', 'Company'), navDoctype('crm.Contact', 'Contact')];

		await loadForDomain(driver, doctypes);

		expect(getCount('crm.Company')).toBe(7);
		expect(getCount('crm.Contact')).toBe(3);
		// Exactly one count call per doctype, all using the count aggregate.
		expect(calls).toHaveLength(2);
		expect(calls.every((c) => (c.params as { aggregate?: string }).aggregate === 'count')).toBe(
			true
		);
	});

	it('preserves a count of 0 ("fetched and empty"), not undefined', async () => {
		// `0` must round-trip through the store so the badge renders `0` rather
		// than `—`. The consumer does `getCount(q) ?? '—'`, so anything `null` OR
		// `undefined` silently falls back to the placeholder — a count of `0` must
		// land as an actual `0` in the store.
		const driver = makeDriverStub([], { 'crm.Company': 0 });
		await loadForDomain(driver, [navDoctype('crm.Company', 'Company')]);
		expect(getCount('crm.Company')).toBe(0);
	});

	it('issues count-mode list calls against the doctype-derived URL segments', async () => {
		const calls: Array<{ domain: string; doctype: string; params: unknown }> = [];
		const driver = makeDriverStub(calls, { 'hr.Employee': 42 });
		await loadForDomain(driver, [navDoctype('hr.Employee', 'Employee')]);

		expect(calls).toEqual([{ domain: 'hr', doctype: 'Employee', params: { aggregate: 'count' } }]);
	});

	it('skips doctypes already resolved', async () => {
		const calls: Array<{ domain: string; doctype: string; params: unknown }> = [];
		const driver = makeDriverStub(calls, { 'crm.Company': 5 });
		const doctypes = [navDoctype('crm.Company', 'Company')];

		await loadForDomain(driver, doctypes);
		expect(calls).toHaveLength(1);

		// Second call should be a no-op — the count is already cached.
		await loadForDomain(driver, doctypes);
		expect(calls).toHaveLength(1);
		expect(getCount('crm.Company')).toBe(5);
	});

	it('clearCounts drops every cached value', async () => {
		const calls: Array<{ domain: string; doctype: string; params: unknown }> = [];
		const driver = makeDriverStub(calls, { 'crm.Company': 9 });
		await loadForDomain(driver, [navDoctype('crm.Company', 'Company')]);
		expect(getCount('crm.Company')).toBe(9);

		clearCounts();
		expect(getCount('crm.Company')).toBeUndefined();
	});

	it('is a no-op for an empty doctype list', async () => {
		const calls: Array<{ domain: string; doctype: string; params: unknown }> = [];
		const driver = makeDriverStub(calls, {});
		await loadForDomain(driver, []);
		expect(calls).toHaveLength(0);
	});

	it('leaves failed doctype counts undefined without blocking the rest', async () => {
		// `crm.Company` rejects; `crm.Contact` should still resolve. The store
		// must not abort the wave on a single rejection.
		const driver: DataDriver = {
			domain: () => ({
				doctype: (dt: string) => ({
					list: vi.fn(async () => {
						if (dt === 'Company') throw new Error('boom');
						const response: ListResponse = { data: [], meta: { count: 4, more: false } };
						return response;
					})
				})
			})
		} as unknown as DataDriver;

		await loadForDomain(driver, [
			navDoctype('crm.Company', 'Company'),
			navDoctype('crm.Contact', 'Contact')
		]);

		expect(getCount('crm.Company')).toBeUndefined();
		expect(getCount('crm.Contact')).toBe(4);
	});
});

describe('invalidateCount', () => {
	it('drops the cached count so the next load refetches it', async () => {
		const calls: Array<{ domain: string; doctype: string; params: unknown }> = [];
		const driver = makeDriverStub(calls, { 'crm.Company': 5 });
		await loadForDomain(driver, [navDoctype('crm.Company', 'Company')]);
		expect(getCount('crm.Company')).toBe(5);
		expect(calls).toHaveLength(1);

		invalidateCount('crm.Company');
		expect(getCount('crm.Company')).toBeUndefined();

		// A stale count must not suppress the refetch: the pending filter
		// skips resolved doctypes, and the invalidation must clear that flag.
		await loadForDomain(driver, [navDoctype('crm.Company', 'Company')]);
		expect(calls).toHaveLength(2);
		expect(getCount('crm.Company')).toBe(5);
	});

	it('leaves other doctypes untouched', async () => {
		const driver = makeDriverStub([], { 'crm.Company': 5, 'crm.Contact': 3 });
		const doctypes = [navDoctype('crm.Company', 'Company'), navDoctype('crm.Contact', 'Contact')];
		await loadForDomain(driver, doctypes);

		invalidateCount('crm.Company');

		expect(getCount('crm.Company')).toBeUndefined();
		expect(getCount('crm.Contact')).toBe(3);
	});

	it('bumps the counts version', async () => {
		const before = getCountsVersion();
		invalidateCount('crm.Company');
		expect(getCountsVersion()).toBeGreaterThan(before);
	});

	it('is a no-op for a doctype that was never fetched, but still bumps', () => {
		const before = getCountsVersion();
		invalidateCount('crm.Company');
		expect(getCount('crm.Company')).toBeUndefined();
		expect(getCountsVersion()).toBeGreaterThan(before);
	});

	it('drops a fetch that was in flight when the invalidation landed', async () => {
		// The race the token guard exists for: the import completes while a
		// pre-import count fetch is still running. The late result must not
		// reinstall the pre-import count, and a refetch must be possible.
		let releaseStale!: (count: number) => void;
		const stale = new Promise<ListResponse>((resolve) => {
			releaseStale = (count: number) => resolve({ data: [], meta: { count, more: false } });
		});
		const calls: Array<{ domain: string; doctype: string; params: unknown }> = [];
		const driver = makeDriverStub(calls, { 'crm.Company': 5 });
		vi.spyOn(driver.domain('crm'), 'doctype').mockImplementationOnce(
			() =>
				({
					list: () => stale
				}) as unknown as DataSource
		);

		const wave = loadForDomain(driver, [navDoctype('crm.Company', 'Company')]);
		invalidateCount('crm.Company');
		releaseStale(5); // the pre-import answer, now stale
		await wave;

		// The stale write was dropped, and the refetch is no longer blocked.
		expect(getCount('crm.Company')).toBeUndefined();
		await loadForDomain(driver, [navDoctype('crm.Company', 'Company')]);
		expect(getCount('crm.Company')).toBe(5);
	});
});

describe('clearDomainCounts', () => {
	it('drops the domain counts and keeps other domains', async () => {
		const driver = makeDriverStub([], { 'crm.Company': 5, 'crm.Contact': 3, 'hr.Employee': 9 });
		await loadForDomain(driver, [
			navDoctype('crm.Company', 'Company'),
			navDoctype('crm.Contact', 'Contact'),
			navDoctype('hr.Employee', 'Employee')
		]);

		clearDomainCounts('crm');

		expect(getCount('crm.Company')).toBeUndefined();
		expect(getCount('crm.Contact')).toBeUndefined();
		expect(getCount('hr.Employee')).toBe(9);
	});

	it('bumps the version even when nothing was cached', () => {
		// A fresh import adds doctypes the store never counted — the bump is
		// what re-arms the sidebar fetch for them.
		const before = getCountsVersion();
		clearDomainCounts('newdom');
		expect(getCountsVersion()).toBeGreaterThan(before);
	});

	it('drops a fetch in flight for the domain', async () => {
		let releaseStale!: (count: number) => void;
		const stale = new Promise<ListResponse>((resolve) => {
			releaseStale = (count: number) => resolve({ data: [], meta: { count, more: false } });
		});
		const driver = makeDriverStub([], { 'crm.Company': 5 });
		vi.spyOn(driver.domain('crm'), 'doctype').mockImplementationOnce(
			() =>
				({
					list: () => stale
				}) as unknown as DataSource
		);

		const wave = loadForDomain(driver, [navDoctype('crm.Company', 'Company')]);
		clearDomainCounts('crm');
		releaseStale(5);
		await wave;

		expect(getCount('crm.Company')).toBeUndefined();
	});
});

describe('clearCounts', () => {
	it('drops a fetch that was in flight across the logout', async () => {
		// A late pre-logout result must not land in the fresh session's store.
		let releaseStale!: (count: number) => void;
		const stale = new Promise<ListResponse>((resolve) => {
			releaseStale = (count: number) => resolve({ data: [], meta: { count, more: false } });
		});
		const driver = makeDriverStub([], { 'crm.Company': 5 });
		vi.spyOn(driver.domain('crm'), 'doctype').mockImplementationOnce(
			() =>
				({
					list: () => stale
				}) as unknown as DataSource
		);

		const wave = loadForDomain(driver, [navDoctype('crm.Company', 'Company')]);
		clearCounts();
		releaseStale(5);
		await wave;

		expect(getCount('crm.Company')).toBeUndefined();
	});
});
