// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { error } from '@sveltejs/kit';
import { DocumentDataDriver } from '$lib/datasource/DocumentDriver';
import { DoctypeRegistry } from '$lib/datasource/DoctypeRegistry.js';
import { DataSourceError } from '$lib/datasource/types.js';
import { errorMessage } from '$lib/datasource/bannerError.js';
import { doctypeRegistryCache } from '$lib/datasource/clientCache.js';
import { parseDoctypeDef, type DoctypeDef } from '$lib/doctype/types.js';
import * as m from '$lib/paraglide/messages';

/**
 * Shared route-load helpers for the doctype-facing routes.
 *
 * Every `/{domain}/{doctype}...` route resolves the doctype definition from the
 * 60s-TTL cached `DoctypeRegistry` (one `core.DocType?items=500` round-trip per
 * session window). The cached snapshot can lag a freshly-created doctype, so a
 * miss invalidates the cache and refetches once before declaring 404.
 */

/** Build an SSR-safe driver bound to SvelteKit's `event.fetch`. */
export function buildDriver(fetch: typeof globalThis.fetch): DocumentDataDriver {
	return new DocumentDataDriver('', fetch);
}

/**
 * Rethrow a document-fetch failure from a route load as a SvelteKit error.
 *
 * A `DataSourceError` keeps the backend's HTTP status, so the error page
 * classifies from structured data: a 404 renders the not-found page, a 410
 * the deleted page, a 500 stays a server error. Any other failure (network,
 * parse) becomes a 500.
 */
export function rethrowLoadError(err: unknown, fallback: string): never {
	if (err instanceof DataSourceError) {
		throw error(err.status, errorMessage(err, fallback));
	}
	throw error(500, errorMessage(err, fallback));
}

/**
 * Resolve a doctype definition by qualified name, refetching the registry once
 * on a miss. Throws a 404 SvelteKit error when the doctype is unknown.
 */
export async function resolveDoctype(
	domain: string,
	doctypeLabel: string,
	fetch?: typeof globalThis.fetch
): Promise<{ def: DoctypeDef; registry: DoctypeRegistry }> {
	const driver = fetch ? buildDriver(fetch) : new DocumentDataDriver('');
	const qualifiedName = `${domain}.${doctypeLabel}`;

	let registry = await DoctypeRegistry.cached(driver);
	let match = registry.doctypeDefinitions.get(qualifiedName);

	if (!match) {
		// The cached snapshot can lag behind a freshly-created doctype (60s TTL).
		// Invalidate and refetch once before declaring 404.
		doctypeRegistryCache.invalidate();
		registry = await DoctypeRegistry.from(driver);
		match = registry.doctypeDefinitions.get(qualifiedName);
	}

	if (!match) {
		throw error(404, m.errors_doctype_not_found({ name: qualifiedName }));
	}

	return { def: parseDoctypeDef(match as Record<string, unknown>) as DoctypeDef, registry };
}
