// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { SortState } from '$lib/table/types.js';

/**
 * Per-browser memory of a listing's manual state — the sort the user picked,
 * the filter map they built in the toolbar (the `search` term included), and
 * the rows-per-page they chose.
 *
 * The state is keyed per parent doctype, per collection view, and per trash
 * mode, so every listing tab reopens exactly as the user left it. This is
 * presentation state only: the saved `core.CollectionView` config stays the
 * shared definition.
 *
 * Follows the localStorage discipline of `recentDocuments.svelte.ts`: the
 * `facet.` key prefix, browser-gated access (reads return `null`, writes are
 * no-ops on the server), and tolerant parsing (a corrupt or wrong-shaped blob
 * reads as absent). Nothing here is reactive — the `Table` reads once per view
 * change and writes on user edits.
 */

const KEY_PREFIX = 'facet.viewState.';

/** The persisted state of one listing view. */
export interface PersistedViewState {
	/** The user's sort. `null` when the listing has no active sort. */
	sort: SortState | null;
	/** The manual filter map (`field__op` → value). */
	filters: Record<string, unknown>;
	/** The rows-per-page the user picked in the footer selector. */
	rowsPerPage?: number;
}

/** Trash mode of the listing — live rows or tombstones. */
export type ViewStateMode = 'live' | 'deleted';

/**
 * The localStorage key of one listing view: the parent doctype projection id
 * (e.g. `crm.Deal`), the collection view id (or `default` for the synthetic
 * Default tab and tab-less listings), and the trash mode.
 */
export function viewStateStorageKey(
	parentDocId: string,
	viewId: string,
	mode: ViewStateMode
): string {
	return `${KEY_PREFIX}${parentDocId}.${viewId}.${mode}`;
}

function isPlainObject(v: unknown): v is Record<string, unknown> {
	return typeof v === 'object' && v !== null && !Array.isArray(v);
}

/** Accepts only `{ key, desc }`; anything else reads as "no sort". */
function parseSort(v: unknown): SortState | null {
	if (!isPlainObject(v)) return null;
	const { key, desc } = v;
	if (typeof key !== 'string' || key === '' || typeof desc !== 'boolean') return null;
	return { key, desc };
}

/** Accepts only an integer ≥ 1; anything else reads as "not persisted". */
function parseRowsPerPage(v: unknown): number | undefined {
	if (typeof v !== 'number' || !Number.isInteger(v) || v < 1) return undefined;
	return v;
}

/**
 * Read the persisted state of one listing view. Returns `null` when the entry
 * does not exist, is corrupt, or is not an object — the caller then keeps its
 * current seed. Malformed members degrade one by one (sort → `null`, filters
 * → `{}`, rowsPerPage dropped).
 */
export function loadViewState(key: string): PersistedViewState | null {
	if (typeof window === 'undefined') return null;
	try {
		const raw = window.localStorage.getItem(key);
		if (!raw) return null;
		const parsed: unknown = JSON.parse(raw);
		if (!isPlainObject(parsed)) return null;
		const rowsPerPage = parseRowsPerPage(parsed.rowsPerPage);
		return {
			sort: parseSort(parsed.sort),
			filters: isPlainObject(parsed.filters) ? parsed.filters : {},
			...(rowsPerPage !== undefined ? { rowsPerPage } : {})
		};
	} catch {
		return null;
	}
}

/**
 * Write the persisted state of one listing view. A no-op on the server and
 * when storage is unavailable (private mode, quota) — the listing keeps its
 * in-memory state.
 */
export function saveViewState(key: string, state: PersistedViewState): void {
	if (typeof window === 'undefined') return;
	try {
		window.localStorage.setItem(key, JSON.stringify(state));
	} catch {
		/* storage unavailable — the in-memory state still works */
	}
}
