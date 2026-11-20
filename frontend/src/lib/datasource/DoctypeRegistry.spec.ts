// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { MockDataDriver } from './MockDriver.js';
import { DoctypeRegistry, fetchDoctypeDefinitions } from './DoctypeRegistry.js';
import { doctypeRegistryCache } from './clientCache.js';
import type { DataDriver } from './driver.js';

// ── MockDataDriver fast path (synchronous doctypeDefinitions) ──────────────

describe('DoctypeRegistry — MockDataDriver fast path', () => {
	it('reuses the in-memory doctypeDefinitions map', async () => {
		const driver = new MockDataDriver();
		driver.registerDoctype('hr', 'Employee', { doctype: 'Employee', domain: 'hr' });

		const reg = await DoctypeRegistry.from(driver);
		expect(reg.doctypeDefinitions.get('hr.Employee')).toEqual({
			doctype: 'Employee',
			domain: 'hr'
		});
	});

	it('delegates domain() to the underlying driver', () => {
		const driver = new MockDataDriver();
		const reg = new DoctypeRegistry(driver);
		expect(reg.domain('hr')).toBe(driver.domain('hr'));
	});

	it('satisfies the DoctypeDefinitionRegistry shape', () => {
		const driver = new MockDataDriver();
		const reg = new DoctypeRegistry(driver);
		expect(reg.doctypeDefinitions).toBeInstanceOf(Map);
		expect(typeof reg.domain).toBe('function');
	});

	it('fetchDoctypeDefinitions returns the same map instance for MockDataDriver', async () => {
		const driver = new MockDataDriver();
		const fetched = await fetchDoctypeDefinitions(driver);
		expect(fetched).toBe(driver.doctypeDefinitions);
	});
});

// ── HTTP driver path (fetches from core.DocType, no in-memory map) ────────

/**
 * Minimal fake driver standing in for `DocumentDataDriver`. It does not expose
 * a `doctypeDefinitions` map, so `fetchDoctypeDefinitions` must fall back to
 * listing `core.DocType`.
 */
function fakeHttpDriver(
	docs: { data: Record<string, unknown>; meta: { id: string } }[]
): DataDriver {
	return {
		domain(name: string) {
			return {
				doctype(_n: string) {
					return {
						async list() {
							return {
								data: name === 'core' && _n === 'DocType' ? docs : [],
								meta: { count: docs.length, more: false }
							};
						}
					};
				}
			};
		}
	} as unknown as DataDriver;
}

describe('DoctypeRegistry — HTTP fetch path', () => {
	it('builds the map from core.DocType projections when no in-memory map', async () => {
		const driver = fakeHttpDriver([
			{ data: { domain: 'hr', doctype: 'Employee', color: '#abc' }, meta: { id: 'dt1' } },
			{ data: { domain: 'crm', doctype: 'Company' }, meta: { id: 'dt2' } },
			{ data: { domain: 'hr', doctype: undefined }, meta: { id: 'dt3' } }
		]);

		const reg = await DoctypeRegistry.from(driver);
		expect(reg.doctypeDefinitions.size).toBe(2);
		expect(reg.doctypeDefinitions.get('hr.Employee')?.color).toBe('#abc');
		expect(reg.doctypeDefinitions.get('crm.Company')).toEqual({
			domain: 'crm',
			doctype: 'Company'
		});
	});

	it('produces an empty map when no DocType documents exist', async () => {
		const driver = fakeHttpDriver([]);
		const reg = await DoctypeRegistry.from(driver);
		expect(reg.doctypeDefinitions.size).toBe(0);
	});

	it('fetchDoctypeDefinitions returns a Map (not the driver) for the HTTP path', async () => {
		const driver = fakeHttpDriver([
			{ data: { domain: 'hr', doctype: 'Employee' }, meta: { id: 'dt1' } }
		]);
		const fetched = await fetchDoctypeDefinitions(driver);
		expect(fetched).toBeInstanceOf(Map);
		expect(fetched.get('hr.Employee')).toEqual({ domain: 'hr', doctype: 'Employee' });
	});
});

describe('DoctypeRegistry.cached', () => {
	beforeEach(() => {
		doctypeRegistryCache.clear();
	});
	afterEach(() => {
		doctypeRegistryCache.clear();
	});

	it('returns a DoctypeRegistry built from the given driver', async () => {
		const driver = fakeHttpDriver([
			{ data: { domain: 'hr', doctype: 'Employee' }, meta: { id: 'dt1' } }
		]);
		const reg = await DoctypeRegistry.cached(driver);
		expect(reg).toBeInstanceOf(DoctypeRegistry);
		expect(reg.doctypeDefinitions.get('hr.Employee')).toEqual({
			domain: 'hr',
			doctype: 'Employee'
		});
	});

	it('delegates to `from` on the server path (no module-level cache)', async () => {
		// The module-level `isBrowser` is `false` in the Vitest `server` project, so
		// `cached` is a thin wrapper around `from` here — two reads produce two
		// distinct registry instances (no in-memory sharing). The browser caching
		// contract is covered by `clientCache.spec.ts` via its injectable
		// `isBrowserFn` predicate.
		const driver = fakeHttpDriver([
			{ data: { domain: 'hr', doctype: 'Employee' }, meta: { id: 'dt1' } }
		]);
		const a = await DoctypeRegistry.cached(driver);
		const b = await DoctypeRegistry.cached(driver);
		expect(a).not.toBe(b); // different instances — server path doesn't cache.
		expect(a.doctypeDefinitions).toEqual(b.doctypeDefinitions);
	});
});
