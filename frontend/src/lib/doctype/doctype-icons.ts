// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { Component } from 'svelte';
import * as icons from '@lucide/svelte/icons';
import { Diamond } from '@lucide/svelte';

// `@lucide/svelte/icons` re-exports the barrel (`Icon`, `context`, helpers)
// alongside the icons. The nested `icons` namespace is the pure icon set —
// nothing but the 1700+ icon components — so iterating it needs no filtering.
const ICON_NAMESPACE = icons.icons;

/**
 * Virtual, in-memory Lucide icon catalog for doctype icon selection.
 *
 * The full Lucide set is ~1700 icons. Mounting every icon as a Svelte
 * component up front is wasteful, so this module exposes an **async,
 * paginated, filtered** search API that mimics an AJAX backend without a
 * network hop. Only the icons the user actually renders are ever mounted.
 *
 * Storage values are the kebab-case Lucide names (e.g. `"building-2"`),
 * which are stable identifiers. The Lucide export names are PascalCase
 * (`Building2`); we translate between them here.
 *
 * The module builds a name → component map lazily on first access. Of the
 * ~1700 names, only `kebabCase(value)` and `humanize(name)` were derived —
 * no Svelte components are instantiated until the user selects one.
 */

/** One selectable icon option, shaped for `Select`'s `SelectOption`. */
export interface DoctypeIconOption {
	value: string;
	label: string;
	icon: Component;
}

/** Result page returned by {@link searchDoctypeIcons}. */
export interface DoctypeIconPage {
	/** The page of options for the current query + cursor. */
	options: DoctypeIconOption[];
	/** Opaque cursor to pass back for the next page. `null` when exhausted. */
	next: string | null;
	/** Total matches for the current query (used for the "N icons" hint). */
	total: number;
}

let _catalog: Map<string, Component> | null = null;

/**
 * Lazily build the name → component map on first use.
 *
 * Built lazily (not at module load) because `@lucide/svelte/icons` is a
 * re-export barrel; when this module is first evaluated during a circular
 * import the namespace may not be fully populated yet, and `Object.entries`
 * would return an empty map. Deferring until first access guarantees the
 * namespace is ready.
 */
function catalog(): Map<string, Component> {
	if (_catalog) return _catalog;
	const map = new Map<string, Component>();
	for (const [name, comp] of Object.entries(ICON_NAMESPACE)) {
		map.set(dashify(name), comp as Component);
	}
	// Only cache a non-empty catalog. If this runs while the barrel is still
	// mid-evaluation during a circular import, the namespace may be empty;
	// caching that would permanently break icon resolution. Return the empty map
	// but retry on the next access, by which time the namespace is populated.
	if (map.size > 0) _catalog = map;
	return map;
}

/** @internal — exposed for tests and debugging the catalog contents. */
export const DOCTYPE_ICON_CATALOG = {
	get size(): number {
		return catalog().size;
	},
	has(key: string): boolean {
		return catalog().has(key);
	},
	keys(): IterableIterator<string> {
		return catalog().keys();
	}
};

/** Fallback icon when the stored value is absent or unknown. */
export const DOCTYPE_DEFAULT_ICON: Component = Diamond;

const PAGE_SIZE = 48;

/**
 * Resolve a stored kebab-case icon value to its Lucide component. Returns
 * the {@link Diamond} fallback when the value is empty or not in the catalog.
 */
export function resolveDoctypeIcon(value?: string | null): Component {
	if (!value) return DOCTYPE_DEFAULT_ICON;
	return catalog().get(value) ?? DOCTYPE_DEFAULT_ICON;
}

/**
 * Search the in-memory icon catalog as if querying a remote backend.
 *
 * Filters icons by a case-insensitive substring over both the kebab-case
 * value and a humanized label, then returns a single page. Pass the returned
 * `cursor` to fetch the next page; a `null` cursor means no more results.
 *
 * @param query  Filter text ("" lists from the start).
 * @param cursor  Opaque page cursor from a previous call, or `null`/absent for the first page.
 * @param pageSize  Number of icons per page (default {@link PAGE_SIZE}).
 */
export async function searchDoctypeIcons(
	query: string,
	cursor?: string | null,
	pageSize: number = PAGE_SIZE
): Promise<DoctypeIconPage> {
	const q = query.trim().toLowerCase();
	const all = [...catalog().entries()].filter(
		([value]) => value.includes(q) || humanize(value).toLowerCase().includes(q)
	);

	// The cursor is the zero-based index of the next item to return.
	const start = cursor == null ? 0 : Number(cursor);
	const safeStart = Number.isFinite(start) && start >= 0 ? start : 0;
	const page = all.slice(safeStart, safeStart + pageSize);
	const options = page.map(([value, icon]) => ({ value, label: humanize(value), icon }));
	const nextStart = safeStart + page.length;
	const next: string | null = nextStart < all.length ? String(nextStart) : null;

	return { options, next, total: all.length };
}

/** Human-readable label: kebab-case → Title Case ("building-2" → "Building 2"). */
function humanize(value: string): string {
	return value
		.split('-')
		.map((part) => (part.length === 0 ? part : part[0].toUpperCase() + part.slice(1)))
		.join(' ');
}

/** PascalCase export name → kebab-case value ("Building2" → "building-2"). */
function dashify(pascal: string): string {
	return pascal
		.replace(/([a-z0-9])([A-Z])/g, '$1-$2')
		.replace(/([A-Z])([A-Z][a-z])/g, '$1-$2')
		.replace(/([a-z])([0-9])/g, '$1-$2')
		.toLowerCase();
}
