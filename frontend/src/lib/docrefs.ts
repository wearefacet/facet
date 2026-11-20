// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Document references — the document half of the markdown `@` reference
 * picker, the doctype label rules, and the chip label resolver.
 *
 * A reference is an ordinary markdown link whose URL is the target's
 * canonical colon-form URN (`urn:facet:{domain}:{Doctype}:{id}`). The label
 * is plain text (no glyph — a mention label is the one that keeps `@`).
 * `DocURI.parse` and `Document::Links` accept the colon form only, so this
 * module owns the storage form (see `doc/backend/links.md` → URN form).
 *
 * Chip labels resolve live through `show()` with status inspection —
 * `resolveRefLabel` collapses every failure to `null`, which is not enough
 * for the chip states (ok / deleted / forbidden / unresolvable), so this
 * module ships its own resolver.
 */

import { DocumentDataSource } from './datasource/DocumentDataSource.js';
import { DataSourceError } from './datasource/types.js';
import { splitQualifiedDoctype } from './datasource/qualifiedRef.js';
import { loadDoctypeCatalogue } from './doctypeCatalogue.js';
import { can } from './permissions.svelte';

/** Rows the scoped mode fetches per doctype. */
export const SCOPED_SEARCH_LIMIT = 25;

/** Segments of the canonical colon-form document URN: `urn:facet:…`. */
const URN_SEGMENTS = 5;

/** Backend identifier shapes (doc/backend/links.md → URN form). */
const DOMAIN_RE = /^_?[a-z0-9][a-z0-9-]*$/;
const DOCTYPE_RE = /^[A-Z][a-zA-Z0-9]*$/;
const OPAQUE_RE = /^[A-Za-z0-9._-]+$/;

/** A parsed colon-form document URN. */
export interface DocUrn {
	domain: string;
	doctype: string;
	id: string;
}

/** Builds the canonical colon-form URN for a document. */
export function docUrn(domain: string, doctype: string, id: string): string {
	return `urn:facet:${domain}:${doctype}:${id}`;
}

/**
 * Parses a colon-form document URN from a link href. Returns `null` for
 * anything else — artifact URNs (four segments), state-pinned URNs
 * (`…?state=…`, rendered as plain links), and other schemes. Malformed
 * segments never parse: a chip can only name a real document shape.
 */
export function parseDocUrn(href: string | null | undefined): DocUrn | null {
	if (!href || !href.startsWith('urn:facet:')) return null;
	if (href.includes('?')) return null;
	const parts = href.split(':');
	if (parts.length !== URN_SEGMENTS) return null;
	const [, scheme, domain, doctype, id] = parts;
	if (scheme !== 'facet' || domain === 'artifact') return null;
	if (!domain || !doctype || !id) return null;
	if (!DOMAIN_RE.test(domain) || !DOCTYPE_RE.test(doctype) || !OPAQUE_RE.test(id)) return null;
	return { domain, doctype, id };
}

/** The markdown link a picked document reference inserts. */
export function docRefMarkdown(domain: string, doctype: string, id: string, label: string): string {
	return `[${label}](${docUrn(domain, doctype, id)})`;
}

/** The live show route of a document — the shape paste-to-chip detects. */
export function showRoute(domain: string, doctype: string, id: string): string {
	return `/${domain}/${doctype}/${id}`;
}

/**
 * Parses a Facet document show URL (`/{domain}/{Doctype}/{id}`) from a
 * pasted URL. Accepts any origin (the app may run behind different hosts);
 * rejects non-show paths and the API surface.
 */
export function parseShowUrl(url: string): DocUrn | null {
	let path: string;
	try {
		path = new URL(url, 'http://facet.invalid').pathname;
	} catch {
		return null;
	}
	const segments = path.split('/').filter(Boolean);
	if (segments.length !== 3) return null;
	const [domain, doctype, id] = segments;
	if (domain === 'api') return null;
	if (!DOMAIN_RE.test(domain) || !DOCTYPE_RE.test(doctype) || !OPAQUE_RE.test(id)) return null;
	return { domain, doctype, id };
}

/**
 * One "Filter by type" / scoped-mode doctype option of the picker.
 * The human label is the plural noun (`plural_label` → `fallbackPlural`),
 * never `core.DocType.display_name` — that field labels documents.
 */
export interface DocTypeOption {
	/** Qualified `domain.Doctype`. */
	target: string;
	domain: string;
	/** Doctype name (CamelCase). */
	name: string;
	/** Human plural noun — the group header text. */
	pluralLabel: string;
	/** Icon name from `core.DocType.icon`, when declared. */
	icon?: string;
	/** Visual colour from `core.DocType.color`, when declared. */
	color?: string;
}

/**
 * The picker's doctype narrowing match — case-insensitive substring over
 * the human plural label, the technical name, and the qualified id (the
 * `ReferencePicker` rules).
 */
export function doctypeMatches(option: DocTypeOption, query: string): boolean {
	const q = query.trim().toLowerCase();
	if (!q) return true;
	return (
		option.pluralLabel.toLowerCase().includes(q) ||
		option.name.toLowerCase().includes(q) ||
		option.target.toLowerCase().includes(q)
	);
}

/**
 * Loads the readable doctypes for "Filter by type": the doctype catalogue
 * filtered through the permissions store. A doctype without a `search`
 * template stays in the list — scoped mode browses it with an empty query,
 * it just never joins typed search.
 */
export async function listDoctypes(fetchFn?: typeof fetch): Promise<DocTypeOption[]> {
	const { entries } = await loadDoctypeCatalogue(fetchFn);
	return entries
		.filter((entry) => can(entry.target, 'read'))
		.map((entry) => ({
			target: entry.target,
			domain: entry.domain,
			name: entry.label,
			pluralLabel: entry.pluralLabel,
			icon: entry.icon,
			color: entry.color
		}));
}

/** One record row of the scoped mode. */
export interface DocCandidate {
	id: string;
	label: string;
	domain: string;
	doctype: string;
}

/**
 * Searches (or with an empty query, browses) one doctype through the list
 * API's `search` filter — the same call `ReferencePicker` makes. A denied
 * request degrades to an empty list, never an error.
 */
export async function searchDoctype(
	qualified: string,
	q: string,
	fetchFn?: typeof fetch
): Promise<DocCandidate[]> {
	const parts = splitQualifiedDoctype(qualified);
	if (!parts) return [];
	try {
		const ds = new DocumentDataSource(parts.domain, parts.doctype, undefined, fetchFn);
		const term = q.trim();
		const res = await ds.list({
			filters: term ? { search: term } : {},
			items: SCOPED_SEARCH_LIMIT
		});
		return res.data.map(({ meta }) => ({
			id: meta.id,
			label: meta.display_name ?? meta.id,
			domain: parts.domain,
			doctype: parts.doctype
		}));
	} catch (e) {
		if (e instanceof DataSourceError) return [];
		throw e;
	}
}

/** Render state of a reference chip's live label. */
export type ChipResolution =
	| { status: 'ok'; label: string }
	| { status: 'deleted' }
	| { status: 'forbidden' }
	| { status: 'unknown' };

/**
 * Resolves one document's current label with status inspection — the chip
 * resolver cannot reuse `resolveRefLabel`, which collapses every failure to
 * `null`. States: `ok` (live title), `deleted` (404/410 — stored text,
 * struck through), `forbidden` (403 — never render the stored title), and
 * `unknown` (offline or another failure — stored text, neutral style).
 */
export async function resolveChipLabel(
	domain: string,
	doctype: string,
	id: string,
	fetchFn?: typeof fetch
): Promise<ChipResolution> {
	try {
		const ds = new DocumentDataSource(domain, doctype, undefined, fetchFn);
		const res = await ds.doc(id).show();
		return { status: 'ok', label: res.meta.display_name ?? String(res.data['name'] ?? id) };
	} catch (e) {
		if (e instanceof DataSourceError) {
			if (e.status === 403) return { status: 'forbidden' };
			if (e.status === 404 || e.status === 410) return { status: 'deleted' };
		}
		return { status: 'unknown' };
	}
}
