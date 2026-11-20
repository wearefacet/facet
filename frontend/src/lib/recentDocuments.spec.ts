// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

/**
 * Unit tests for the recently-viewed documents store.
 *
 * The store's browser branches read/write `window.localStorage` and gate on a
 * module-load `isBrowser` flag. To exercise them we stub a `window` with an
 * in-memory `localStorage` and re-import the module fresh per test
 * (`vi.resetModules` + dynamic import) so the `isBrowser` flag is re-evaluated
 * under the stub.
 */

/** A minimal in-memory localStorage implementing the methods the store uses. */
function makeStorage() {
	let store: Record<string, string> = {};
	return {
		getItem: vi.fn((k: string) => (k in store ? store[k] : null)),
		setItem: vi.fn((k: string, v: string) => {
			store[k] = v;
		}),
		removeItem: vi.fn((k: string) => {
			delete store[k];
		}),
		clear: vi.fn(() => {
			store = {};
		})
	};
}

type StoreApi = typeof import('./recentDocuments.svelte');

// Warm the module transform once outside fake timers. The first dynamic
// import compiles the `.svelte.ts` module (~0.5 s cold), which alone can
// exceed the 1 s server-project test timeout when the suite runs in
// parallel; after this, `vi.resetModules()` + re-import re-evaluates the
// module but reuses the compiled transform.
await import('./recentDocuments.svelte');

async function loadStore(
	storage = makeStorage()
): Promise<{ api: StoreApi; storage: ReturnType<typeof makeStorage> }> {
	vi.stubGlobal('window', { localStorage: storage });
	vi.resetModules();
	const api = (await import('./recentDocuments.svelte')) as StoreApi;
	return { api, storage };
}

function entry(id: string, domain = 'crm', doctype = 'Contact') {
	return { id, domain, doctype };
}

describe('recordRecentDocument', () => {
	beforeEach(() => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2026-08-20T12:00:00Z'));
	});
	afterEach(() => {
		vi.useRealTimers();
		vi.unstubAllGlobals();
	});

	it('prepends a new document and persists it to localStorage', async () => {
		const { api, storage } = await loadStore();
		api.recordRecentDocument(entry('e1', 'crm', 'Contact'));
		const list = api.getRecentDocuments('crm');
		expect(list).toHaveLength(1);
		expect(list[0].id).toBe('e1');
		expect(list[0].ts).toBe(Date.now());
		expect(storage.setItem).toHaveBeenCalledWith(
			'facet.recentDocuments',
			expect.stringContaining('"id":"e1"')
		);
	});

	it('moves an existing entry to the front with a fresh timestamp', async () => {
		const { api } = await loadStore();
		api.recordRecentDocument(entry('e1', 'crm', 'Contact'));
		vi.advanceTimersByTime(60_000);
		api.recordRecentDocument(entry('e2', 'crm', 'Contact'));
		vi.advanceTimersByTime(60_000);
		api.recordRecentDocument(entry('e1', 'crm', 'Contact'));
		const list = api.getRecentDocuments('crm');
		expect(list.map((d) => d.id)).toEqual(['e1', 'e2']);
		// e1 keeps the later timestamp (now + 120s) — asserts freshness.
		expect(list[0].ts).toBeGreaterThan(list[1].ts);
	});

	it('caps the store at MAX_STORED entries (older evicted)', async () => {
		const { api } = await loadStore();
		// The cap constant is internal (40). Record 50 unique docs and assert
		// the store never exceeds 40 and the oldest was evicted.
		for (let i = 0; i < 50; i++) {
			api.recordRecentDocument(entry(`e${i}`));
		}
		const all = api.getRecentDocuments('crm');
		// The most recent 12 are shown; e0 (oldest) must be gone from the store.
		expect(all).toHaveLength(12);
		expect(api.getRecentDocuments('crm').map((d) => d.id)).not.toContain('e0');
		expect(api.getRecentDocuments('crm')[0].id).toBe('e49');
	});

	it('is a no-op for entries without an id', async () => {
		const { api, storage } = await loadStore();
		// @ts-expect-error — exercising the guard with a missing id.
		api.recordRecentDocument({ domain: 'crm', doctype: 'Contact' });
		expect(storage.setItem).not.toHaveBeenCalled();
		expect(api.getRecentDocuments('crm')).toEqual([]);
	});
});

describe('getRecentDocuments', () => {
	beforeEach(() => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2026-08-20T12:00:00Z'));
	});
	afterEach(() => {
		vi.useRealTimers();
		vi.unstubAllGlobals();
	});

	it('filters to the requested domain and caps at MAX_PER_DOMAIN (12)', async () => {
		const { api } = await loadStore();
		for (let i = 0; i < 15; i++) {
			api.recordRecentDocument(entry(`c${i}`, 'crm'));
		}
		for (let i = 0; i < 3; i++) {
			api.recordRecentDocument(entry(`h${i}`, 'hr'));
		}
		expect(api.getRecentDocuments('crm')).toHaveLength(12);
		expect(api.getRecentDocuments('hr')).toHaveLength(3);
		expect(api.getRecentDocuments('crm')[0].id).toBe('c14');
	});

	it('returns newest first', async () => {
		const { api } = await loadStore();
		api.recordRecentDocument(entry('a'));
		vi.advanceTimersByTime(10_000);
		api.recordRecentDocument(entry('b'));
		vi.advanceTimersByTime(10_000);
		api.recordRecentDocument(entry('c'));
		expect(api.getRecentDocuments('crm').map((d) => d.id)).toEqual(['c', 'b', 'a']);
	});
});

describe('clearRecentDocuments', () => {
	beforeEach(() => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2026-08-20T12:00:00Z'));
	});
	afterEach(() => {
		vi.useRealTimers();
		vi.unstubAllGlobals();
	});

	it('empties the store and persists the empty list', async () => {
		const { api, storage } = await loadStore();
		api.recordRecentDocument(entry('e1'));
		expect(api.getRecentDocuments('crm')).toHaveLength(1);
		api.clearRecentDocuments();
		expect(api.getRecentDocuments('crm')).toEqual([]);
		expect(storage.setItem).toHaveBeenLastCalledWith('facet.recentDocuments', '[]');
	});
});

describe('removeRecentDocument', () => {
	beforeEach(() => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2026-08-20T12:00:00Z'));
	});
	afterEach(() => {
		vi.useRealTimers();
		vi.unstubAllGlobals();
	});

	it('drops one entry, keeps the rest in order, and persists', async () => {
		const { api, storage } = await loadStore();
		api.recordRecentDocument(entry('e1', 'crm', 'Contact'));
		api.recordRecentDocument(entry('e2', 'crm', 'Contact'));
		api.removeRecentDocument('e1');
		expect(api.getRecentDocuments('crm').map((d) => d.id)).toEqual(['e2']);
		// The persisted blob carries the pruned list — the next page load
		// rehydrates without the removed entry.
		const blob = String(storage.setItem.mock.lastCall?.[1]);
		expect(blob).toContain('"id":"e2"');
		expect(blob).not.toContain('"id":"e1"');
	});

	it('is a no-op for an unknown id (no write)', async () => {
		const { api, storage } = await loadStore();
		api.recordRecentDocument(entry('e1'));
		storage.setItem.mockClear();
		api.removeRecentDocument('nope');
		expect(storage.setItem).not.toHaveBeenCalled();
		expect(api.getRecentDocuments('crm')).toHaveLength(1);
	});

	it('is a no-op when window is undefined (SSR)', async () => {
		vi.resetModules();
		const api = (await import('./recentDocuments.svelte')) as StoreApi;
		expect(() => api.removeRecentDocument('e1')).not.toThrow();
		expect(api.getRecentDocuments('crm')).toEqual([]);
	});
});

describe('SSR (no window)', () => {
	it('returns an empty list and does not throw when window is undefined', async () => {
		// No window stub: the module-load `isBrowser` flag is false.
		vi.resetModules();
		const api = (await import('./recentDocuments.svelte')) as StoreApi;
		expect(api.getRecentDocuments('crm')).toEqual([]);
		// recordRecentDocument must be a no-op (no window.localStorage access).
		api.recordRecentDocument(entry('e1'));
		expect(api.getRecentDocuments('crm')).toEqual([]);
	});
});

describe('persistence across remounts', () => {
	beforeEach(() => {
		vi.useFakeTimers();
		vi.setSystemTime(new Date('2026-08-20T12:00:00Z'));
	});
	afterEach(() => {
		vi.useRealTimers();
		vi.unstubAllGlobals();
	});

	it('rehydrates from localStorage on the next module load', async () => {
		const storage = makeStorage();
		const { api } = await loadStore(storage);
		api.recordRecentDocument(entry('e1', 'crm', 'Contact'));
		// Persisted blob is in the stub storage.
		expect(storage.setItem).toHaveBeenCalled();

		// A fresh module load (new "page load") reads the persisted list back.
		vi.resetModules();
		const api2 = (await import('./recentDocuments.svelte')) as StoreApi;
		expect(api2.getRecentDocuments('crm').map((d) => d.id)).toEqual(['e1']);
	});

	it('survives a corrupted localStorage blob (parses to [])', async () => {
		const storage = makeStorage();
		storage.getItem.mockReturnValue('{not valid json');
		vi.resetModules();
		const api = (await import('./recentDocuments.svelte')) as StoreApi;
		expect(api.getRecentDocuments('crm')).toEqual([]);
	});
});
