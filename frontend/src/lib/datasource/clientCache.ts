// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Browser-side TTL cache for rarely-changing API data.
 *
 * The backend already serves 304s for repeated requests (ETag-based), but each
 * 304 is still a full round-trip plus server-side etag evaluation. This module
 * holds the response value in memory for a short window so a second call within
 * the window resolves without a network request at all.
 *
 * ## Browser-only
 *
 * All caches live in module-level state and are written only when
 * `typeof window !== 'undefined'`. On the server we never cache — the same
 * module instance is shared across concurrent SSR requests for different
 * users, so caching there would leak state. This mirrors the
 * `session.svelte.ts` gating rule for `expiresAt` / `refreshing`.
 *
 * ## TTL
 *
 * Every entry has a `expiresAt = Date.now() + TTL_MS`. A hit past `expiresAt`
 * is a miss. Fetcher errors do not poison the cache — the entry is only stored
 * on success.
 *
 * ## In-flight dedup
 *
 * Concurrent callers for the same key share the in-flight fetch promise
 * (preventing the "two capsules on the same page both fetch the same user"
 * pattern). The shared promise is dropped when it settles, so a later call
 * after expiry re-fetches.
 *
 * ## Invalidation
 *
 * Each cache exposes `invalidate(key)` and `clear()`. Mutating paths
 * (`update`, `delete`, `CollectionViewEditor` save, …) call `invalidate` for
 * the keys they touched so the next read observes the new value without
 * waiting for the TTL.
 */

/** Cache lifetime. 60 seconds — chosen for "rarely-changing structural data". */
export const TTL_MS = 60_000;

/**
 * Whether we are running in a browser. Captured at module load. Mirrors the
 * gating used by `session.svelte.ts` (`expiresAt` / `refreshing`).
 *
 * Exported for tests so a fake browser environment can be exercised by
 * re-importing the module with `window` present. The exports of this module
 * are constants and classes that read `isBrowser` at call time, not at
 * construction time — so swapping this flag (or constructing caches with a
 * custom predicate in tests) takes effect immediately.
 */
export const isBrowser = typeof window !== 'undefined';

interface Entry<T> {
	value: T;
	expiresAt: number;
}

/**
 * A key→value TTL cache that also deduplicates concurrent fetches for the same
 * key (the in-flight promise is shared).
 *
 * On the server, `get` always calls the fetcher — no state is kept.
 */
export class TtlCache<K, V> {
	private readonly store = new Map<K, Entry<V>>();
	private readonly inflight = new Map<K, Promise<V>>();

	constructor(
		/**
		 * Override the browser-gate check. Defaults to the module-level
		 * `isBrowser`, which is `false` on the server (Node, SSR) and `true` in
		 * the browser. Tests pass an explicit predicate to exercise either path.
		 */
		private readonly isBrowserFn: () => boolean = () => isBrowser
	) {}

	/**
	 * Return the cached value if it is fresh, otherwise call `fetcher`, store
	 * the result, and return it. Concurrent `get` calls for the same key share
	 * one in-flight fetch promise.
	 *
	 * On the server there is no caching — `fetcher` is always invoked.
	 */
	async get(key: K, fetcher: () => Promise<V>): Promise<V> {
		if (!this.isBrowserFn()) return fetcher();

		const now = Date.now();
		const hit = this.store.get(key);
		if (hit && hit.expiresAt > now) return hit.value;

		// Dedupe concurrent callers — they share one fetch promise.
		const existing = this.inflight.get(key);
		if (existing) return existing;

		// The fetcher promise is set on `inflight` synchronously (before its
		// first `await`) so any concurrently-arriving caller sees it in the
		// map and joins the same in-flight request rather than starting a new
		// one. `promise` is referenced inside its own `finally` to clear itself,
		// so the binding must exist before the IIFE runs — `defer` holds the
		// indirection without tripping TS's use-before-assign check.
		const defer: { promise?: Promise<V> } = {};
		const promise = (async () => {
			try {
				const value = await fetcher();
				this.store.set(key, { value, expiresAt: Date.now() + TTL_MS });
				return value;
			} finally {
				if (this.inflight.get(key) === defer.promise) this.inflight.delete(key);
			}
		})();
		defer.promise = promise;
		this.inflight.set(key, promise);
		return promise;
	}

	/** Drop the cached entry for `key` (e.g. after a mutation on that key). */
	invalidate(key: K): void {
		this.store.delete(key);
	}

	/** Drop every entry. Called on logout. */
	clear(): void {
		this.store.clear();
		this.inflight.clear();
	}
}

/**
 * Cache whose key is "nothing" — a singleton result. Used for `core.DocType`
 * listing (the whole registry) and `core.Domain` listing.
 *
 * The signature mirrors {@link TtlCache.get}: `get(fetcher)`, no key.
 */
export class SingletonTtlCache<V> {
	private readonly inner: TtlCache<undefined, V>;
	constructor(isBrowserFn: () => boolean = () => isBrowser) {
		this.inner = new TtlCache<undefined, V>(isBrowserFn);
	}
	get(fetcher: () => Promise<V>): Promise<V> {
		return this.inner.get(undefined, fetcher);
	}
	invalidate(): void {
		this.inner.invalidate(undefined);
	}
	clear(): void {
		this.inner.clear();
	}
}

/** Drop every cached entry across every cache in this module. Called on logout. */
const allCaches: Array<{ clear: () => void }> = [];

/** Register a cache for global invalidation on logout. Preserves its type. */
function register<T extends { clear: () => void }>(cache: T): T {
	allCaches.push(cache);
	return cache;
}

/**
 * Register a `clear` callback that runs with {@link invalidateAllClientCaches}
 * (logout, role switch). Stateful stores that are not plain TTL caches — e.g.
 * the currency store — use this to drop their module-level rows alongside the
 * caches here, so the next login re-fetches under the new session.
 */
export function onInvalidateAllClientCaches(clear: () => void): void {
	allCaches.push({ clear });
}

// ── Definition caches (rarely change; shared across the whole UI) ──────────

/**
 * `core.DocType` registry — the full doctype-definition map, keyed by
 * `"domain.Doctype"`. Backed by `DoctypeRegistry.from`.
 */
export const doctypeRegistryCache = register(new SingletonTtlCache<unknown>());

/**
 * `core.Domain` listing — used by `buildNavModel` for domain colors/labels.
 * Backed by `driver.domain('core').doctype('Domain').list()`.
 */
export const domainListCache = register(new SingletonTtlCache<unknown>());

/**
 * `core.DocumentView` children of a `core.DocType` projection — the per-doctype
 * view templates (`view` / `quickView` / `form` / …). Keyed by the parent
 * `core.DocType` projection id (e.g. `"crm.Company"`).
 */
export const doctypeViewsCache = register(new TtlCache<string, unknown>());

/**
 * `core.CollectionView` children of a `core.DocType` projection — the saved
 * listing configurations for a doctype. Keyed by the parent `core.DocType`
 * projection id.
 */
export const collectionViewsCache = register(new TtlCache<string, unknown>());

// ── Document show() cache (per-document; invalidated on mutation) ─────────

/**
 * `DocumentRef.show()` result cache. Keyed by the qualified doc URL
 * (e.g. `/Api/iam/Account/account_recruiter_kim`).
 *
 * Same TTL as the definition caches. Mutations on a document invalidate the
 * entry for that document's URL.
 */
export const documentShowCache = register(new TtlCache<string, unknown>());

/** Clear every cache in this module. Called on logout. */
export function invalidateAllClientCaches(): void {
	for (const c of allCaches) c.clear();
}
