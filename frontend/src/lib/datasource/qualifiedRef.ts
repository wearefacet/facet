// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { DataDriver } from './driver.js';

/**
 * Qualified reference helpers for `domain.Doctype.<id>` reference values —
 * the form stored by `reference` fields, comment authors, and attachment
 * uploaders. Ids are opaque and may contain dots, so the doctype/id split
 * rides on the second dot, not the last.
 */

/** A parsed qualified reference. */
export interface QualifiedRef {
	domain: string;
	doctype: string;
	/** Everything after the second dot — ids are opaque and may contain dots. */
	id: string;
}

/**
 * Split a `domain.Doctype.<id>` reference. Returns `null` when the value is
 * not qualified (missing either separator) and therefore cannot name a
 * document.
 */
export function splitQualifiedRef(ref: unknown): QualifiedRef | null {
	const key = String(ref ?? '');
	const first = key.indexOf('.');
	const second = first < 1 ? -1 : key.indexOf('.', first + 1);
	if (second < 0) return null;
	return {
		domain: key.slice(0, first),
		doctype: key.slice(first + 1, second),
		id: key.slice(second + 1)
	};
}

/**
 * Split a `domain.Doctype` doctype token — the qualified form carried by
 * `reference` field declarations, pickers, and driver routing. Returns
 * `null` when the token has no separator or an empty domain; a bare
 * doctype name cannot address a domain.
 */
export function splitQualifiedDoctype(ref: unknown): { domain: string; doctype: string } | null {
	const key = String(ref ?? '');
	const first = key.indexOf('.');
	if (first < 1) return null;
	return { domain: key.slice(0, first), doctype: key.slice(first + 1) };
}

/**
 * Resolve a qualified reference to a human label: the target document's
 * `display_name`, falling back to its `name` field, then to the id itself.
 * Unqualified references and failed lookups resolve to `null` — callers
 * degrade to an unknown-identity placeholder.
 */
export async function resolveRefLabel(driver: DataDriver, ref: unknown): Promise<string | null> {
	const parts = splitQualifiedRef(ref);
	if (!parts) return null;
	try {
		const res = await driver.domain(parts.domain).doctype(parts.doctype).doc(parts.id).show();
		return res.meta.display_name ?? String(res.data['name'] ?? parts.id);
	} catch {
		return null;
	}
}
