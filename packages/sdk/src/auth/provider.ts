// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/** Supplies the bearer credential for one Facet instance. */
export interface TokenProvider {
	/** The current bearer token, or `null` when no credential is available. */
	getToken(): Promise<string | null>;
	/**
	 * Produces a fresh bearer token after a `401`. The HTTP layer calls it
	 * once and retries the request with the new header. A failed refresh
	 * raises `AuthError`. Optional — without it, a `401` surfaces as a plain
	 * `ApiError`.
	 */
	refreshOn401?(): Promise<string>;
}

/** A provider that always returns one static value, e.g. an `fct_` API key. */
export function staticKey(value: string): TokenProvider {
	return {
		getToken: () => Promise.resolve(value)
	};
}
