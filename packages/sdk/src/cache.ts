// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/** One cached GET response: the validator and the parsed envelope. */
export interface CacheEntry {
	/** ETag validator from the response's `ETag` header. */
	validator: string;
	/** The parsed body of the earlier `200` response. */
	envelope: unknown;
}

/**
 * A store for ETag validators and their cached envelopes.
 *
 * `requestJson` keys the store with `<method> <url>` and only touches it on
 * a GET. A `304` serves the stored object, not a copy — a caller that
 * mutates the returned envelope mutates the cache.
 */
export interface CacheStore {
	/** The entry for this key, or `undefined`. */
	get(key: string): CacheEntry | undefined;
	/** Store or replace the entry for this key. */
	set(key: string, entry: CacheEntry): void;
	/** Drop the entry for this key. */
	delete(key: string): void;
}

/** The cache key for one request: `<method> <url>`. */
export function cacheKey(method: string, url: URL): string {
	return `${method} ${url.href}`;
}

/** A fresh in-memory store. Each client instance holds its own. */
export function memoryCache(): CacheStore {
	const entries = new Map<string, CacheEntry>();
	return {
		get: (key) => entries.get(key),
		set: (key, entry) => {
			entries.set(key, entry);
		},
		delete: (key) => {
			entries.delete(key);
		}
	};
}
