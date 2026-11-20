// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect, vi, beforeEach } from 'vitest';
import { DocumentDataDriver } from './DocumentDriver.js';

/**
 * Regression tests for B-89: a cached `show()` must be droppable from
 * outside the ref's own mutation paths. Bespoke mutation endpoints (the IAM
 * credential routes) bypass the datasource, so the auto-invalidation inside
 * `update()` / `delete()` / `action()` never runs; the host calls
 * `ref.invalidate()` before re-running its route loads. Without it,
 * `invalidateAll` re-runs the load into the still-warm 60s cache and the
 * show page renders stale field values until a manual reload.
 *
 * The real `documentShowCache` singleton is server-gated under Vitest (no
 * `window`), so this file swaps in a browser-gated `TtlCache` for the module
 * under test. The mock is file-scoped — `DocumentDataSource.spec.ts` must
 * keep the real pass-through server behavior.
 */
vi.mock('./clientCache.js', async (importOriginal) => {
	const actual = await importOriginal<typeof import('./clientCache.js')>();
	return { ...actual, documentShowCache: new actual.TtlCache<string, unknown>(() => true) };
});

import { documentShowCache } from './clientCache.js';

const DOC_BODY = { data: { must_change_pw: false }, meta: { id: 'a1' } };

function makeFetch(body: unknown): { fn: typeof fetch; calls: string[] } {
	const calls: string[] = [];
	const fn = vi.fn(async (input: string | URL | Request) => {
		calls.push(typeof input === 'string' ? input : input.toString());
		return new Response(JSON.stringify(body), {
			status: 200,
			headers: { 'Content-Type': 'application/json' }
		});
	});
	return { fn, calls };
}

describe('ConcreteDocumentRef.invalidate — drops the cached show() (B-89)', () => {
	beforeEach(() => {
		documentShowCache.clear();
	});

	it('serves repeated show() from the cache, and invalidate() forces a refetch', async () => {
		const { fn, calls } = makeFetch(DOC_BODY);
		const driver = new DocumentDataDriver('', fn);
		const ref = driver.domain('iam').doctype('Account').doc('a1');

		await ref.show();
		await ref.show();
		expect(calls).toEqual(['/Api/iam/Account/a1']);

		ref.invalidate();
		await ref.show();
		expect(calls).toEqual(['/Api/iam/Account/a1', '/Api/iam/Account/a1']);
	});

	it('invalidate() on a cold ref issues no fetch', async () => {
		const { fn, calls } = makeFetch(DOC_BODY);
		const driver = new DocumentDataDriver('', fn);
		const ref = driver.domain('iam').doctype('Account').doc('a1');

		ref.invalidate();
		expect(calls).toEqual([]);
	});
});
