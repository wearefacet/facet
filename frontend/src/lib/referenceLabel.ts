// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Shared reference-label resolution for document-view surfaces.
 *
 * A stored `reference` value is a qualified id (`"crm.Supplier.01HXYZ…"`) or
 * a bare id paired with the field's declared doctype. Surfaces that render
 * the value as text — the `DvtHeader` subtitle today — need the target
 * document's display label, not the URN. `Capsule` hydrates its own label
 * when a driver is supplied; this module serves the plain-text case with the
 * same label rule.
 *
 * The cache is a `WeakMap` keyed by driver. One driver instance exists per
 * page load, so the cache lives one page: one fetch per distinct referenced
 * document per page. Concurrent callers share the in-flight promise. A
 * failed fetch is not cached — the next render retries. A `410` tombstone
 * caches the surviving label from the error body.
 */

import { displayLabel } from './components/primitives/surfaces/documentIdentity.js';
import { refKey } from './doctype/relationColumns.js';
import type { DataDriver } from './datasource/driver.js';
import { DataSourceError } from './datasource/types.js';

/** Addressable parts of a reference value. */
export interface ReferenceParts {
	domain: string;
	doctype: string;
	id: string;
}

/**
 * Split a reference value into `(domain, doctype, id)`. A qualified value
 * (`"crm.Supplier.01HXYZ"`) parses on its own; a bare id pairs with the
 * field's declared doctype. Returns `null` when neither source yields a
 * doctype — the caller then renders the stored value as-is.
 */
export function referenceParts(value: string, qualifiedDoctype?: string): ReferenceParts | null {
	const first = value.indexOf('.');
	if (first > 0) {
		const second = value.indexOf('.', first + 1);
		if (second > first) {
			const domain = value.slice(0, first);
			const doctype = value.slice(first + 1, second);
			const id = value.slice(second + 1);
			if (domain && doctype && id) return { domain, doctype, id };
		}
	}
	if (!qualifiedDoctype) return null;
	const dot = qualifiedDoctype.indexOf('.');
	if (dot < 1) return null;
	const domain = qualifiedDoctype.slice(0, dot);
	const doctype = qualifiedDoctype.slice(dot + 1);
	if (!domain || !doctype) return null;
	return { domain, doctype, id: value };
}

const labelCache = new WeakMap<DataDriver, Map<string, Promise<string>>>();

/**
 * Resolve the display label of one referenced document over the driver.
 *
 * The label rule mirrors `Capsule`'s hydration: the backend-computed
 * `meta.display_name` first, then the conventional content fields, then the
 * id (`displayLabel` from `documentIdentity.ts`). The promise never rejects
 * — a failure resolves to the stored reference value, and the cache entry is
 * dropped so a later render retries a transient error.
 */
export function referenceLabel(
	driver: DataDriver,
	refId: string,
	qualifiedDoctype?: string
): Promise<string> {
	const parts = referenceParts(refId, qualifiedDoctype);
	if (!parts) return Promise.resolve(refId);
	let cache = labelCache.get(driver);
	if (!cache) {
		cache = new Map();
		labelCache.set(driver, cache);
	}
	const key = refKey(`${parts.domain}.${parts.doctype}`, parts.id);
	const hit = cache.get(key);
	if (hit) return hit;
	const promise = (async () => {
		try {
			const doc = await driver.domain(parts.domain).doctype(parts.doctype).doc(refId).show();
			return displayLabel(doc);
		} catch (err) {
			if (err instanceof DataSourceError && err.status === 410) {
				// Tombstone: the backend carries the surviving label in the error
				// body. Cache it — a retry cannot make the document live again.
				const label = err.meta?.['display_name'];
				if (typeof label === 'string' && label.length > 0) return label;
				return refId;
			}
			// Transient failure — evict so the next render retries.
			cache.delete(key);
			return refId;
		}
	})();
	cache.set(key, promise);
	return promise;
}
