// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { TtlCache, SingletonTtlCache, invalidateAllClientCaches, TTL_MS } from './clientCache.js';

describe('TtlCache — server path (no caching)', () => {
	it('always calls the fetcher when `isBrowser` returns false', async () => {
		const cache = new TtlCache<string, number>(() => false);
		const fetcher = vi.fn(async () => 1);
		await cache.get('k', fetcher);
		await cache.get('k', fetcher);
		await cache.get('k', fetcher);
		expect(fetcher).toHaveBeenCalledTimes(3);
	});

	it('invalidate and clear are no-ops when not caching', () => {
		const cache = new TtlCache<string, number>(() => false);
		expect(() => cache.invalidate('x')).not.toThrow();
		expect(() => cache.clear()).not.toThrow();
	});
});

describe('TtlCache — browser path', () => {
	beforeEach(() => {
		vi.useFakeTimers();
	});
	afterEach(() => {
		vi.useRealTimers();
	});

	it('caches the first result and serves subsequent calls from the cache', async () => {
		const cache = new TtlCache<string, number>(() => true);
		const fetcher = vi.fn(async () => 42);
		expect(await cache.get('k', fetcher)).toBe(42);
		expect(await cache.get('k', fetcher)).toBe(42);
		expect(await cache.get('k', fetcher)).toBe(42);
		expect(fetcher).toHaveBeenCalledTimes(1);
	});

	it('fetches again after the TTL expires', async () => {
		const cache = new TtlCache<string, number>(() => true);
		const fetcher = vi.fn(async () => 1);
		await cache.get('k', fetcher);
		vi.advanceTimersByTime(TTL_MS + 1);
		await cache.get('k', fetcher);
		expect(fetcher).toHaveBeenCalledTimes(2);
	});

	it('does NOT cache a fetcher rejection', async () => {
		const cache = new TtlCache<string, number>(() => true);
		let calls = 0;
		const fetcher = vi.fn(async () => {
			calls++;
			if (calls === 1) throw new Error('boom');
			return 7;
		});
		await expect(cache.get('k', fetcher)).rejects.toThrow('boom');
		expect(await cache.get('k', fetcher)).toBe(7);
		expect(fetcher).toHaveBeenCalledTimes(2);
	});

	it('dedupes concurrent in-flight callers on the same key', async () => {
		const cache = new TtlCache<string, number>(() => true);
		let calls = 0;
		const fetcher = vi.fn(async () => {
			calls++;
			// Yield to the microtask queue so concurrent callers can join the
			// in-flight promise before it resolves. (`vi.useFakeTimers` is on,
			// so we use `queueMicrotask` instead of `setTimeout`.)
			await new Promise<void>((r) => queueMicrotask(r));
			return calls;
		});
		const [a, b, c] = await Promise.all([
			cache.get('k', fetcher),
			cache.get('k', fetcher),
			cache.get('k', fetcher)
		]);
		expect(fetcher).toHaveBeenCalledTimes(1);
		// All three callers receive the same value from one underlying fetch.
		expect(a).toBe(b);
		expect(b).toBe(c);
		expect(a).toBe(1);
	});

	it('invalidate(key) drops only that key', async () => {
		const cache = new TtlCache<string, number>(() => true);
		const fetcher = vi.fn(async (k: string) => k.length);
		await cache.get('a', () => fetcher('a'));
		await cache.get('b', () => fetcher('b'));
		cache.invalidate('a');
		// Next read on 'a' re-fetches; 'b' stays cached.
		await cache.get('a', () => fetcher('a'));
		await cache.get('b', () => fetcher('b'));
		expect(fetcher).toHaveBeenCalledTimes(3);
	});

	it('clear() drops every entry', async () => {
		const cache = new TtlCache<string, number>(() => true);
		const fetcher = vi.fn(async (k: string) => k.length);
		await cache.get('a', () => fetcher('a'));
		await cache.get('b', () => fetcher('b'));
		cache.clear();
		await cache.get('a', () => fetcher('a'));
		await cache.get('b', () => fetcher('b'));
		expect(fetcher).toHaveBeenCalledTimes(4);
	});
});

describe('SingletonTtlCache', () => {
	beforeEach(() => {
		vi.useFakeTimers();
	});
	afterEach(() => {
		vi.useRealTimers();
	});

	it('caches a singleton value under `undefined`', async () => {
		const cache = new SingletonTtlCache<number>(() => true);
		const fetcher = vi.fn(async () => 7);
		expect(await cache.get(fetcher)).toBe(7);
		expect(await cache.get(fetcher)).toBe(7);
		expect(fetcher).toHaveBeenCalledTimes(1);
	});

	it('invalidate forces the next read to refetch', async () => {
		const cache = new SingletonTtlCache<number>(() => true);
		const fetcher = vi.fn(async () => 7);
		await cache.get(fetcher);
		cache.invalidate();
		await cache.get(fetcher);
		expect(fetcher).toHaveBeenCalledTimes(2);
	});

	it('clear works the same way', async () => {
		const cache = new SingletonTtlCache<number>(() => true);
		const fetcher = vi.fn(async () => 7);
		await cache.get(fetcher);
		cache.clear();
		await cache.get(fetcher);
		expect(fetcher).toHaveBeenCalledTimes(2);
	});

	it('server-path predicate bypasses caching', async () => {
		const cache = new SingletonTtlCache<number>(() => false);
		const fetcher = vi.fn(async () => 7);
		await cache.get(fetcher);
		await cache.get(fetcher);
		expect(fetcher).toHaveBeenCalledTimes(2);
	});
});

describe('invalidateAllClientCaches', () => {
	beforeEach(() => {
		vi.useFakeTimers();
	});
	afterEach(() => {
		vi.useRealTimers();
	});

	it('runs without throwing when caches are empty', () => {
		expect(() => invalidateAllClientCaches()).not.toThrow();
	});

	it('clears every registered cache (callables remain usable)', async () => {
		// The exported singleton caches were registered at module load. Clearing
		// them here must not break subsequent reads.
		invalidateAllClientCaches();
		const fetcher = vi.fn(async () => 'ok');
		// Default gate is `false` in node, so this exercises the server path —
		// the entry never gets stored. The contract we assert here is just
		// "no throw, value returned".
		expect(await doctypeViewsCacheRead(fetcher)).toBe('ok');
		expect(fetcher).toHaveBeenCalledTimes(1);
	});
});

// Re-import so we can call `get` on the registered singleton with a typed
// fetcher. Intentionally separate from `invalidateAllClientCaches` above so
// the import is fresh per-test.
async function doctypeViewsCacheRead(fetcher: () => Promise<unknown>): Promise<unknown> {
	const mod = await import('./clientCache.js');
	return mod.doctypeViewsCache.get('test-key', fetcher);
}
