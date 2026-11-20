// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Recently-viewed documents — a localStorage-backed activity list.
 *
 * The dashboard's "Recently viewed" section shows the last documents the user
 * opened in the active domain. There is no backend store for this: the list
 * is purely a per-browser convenience, capped to keep it compact.
 *
 * Mirrors the pattern of `navCounts.svelte.ts`, `permissions.svelte.ts`, and
 * `theme.svelte.ts`: module-level `$state`, getter/setter functions, no
 * `setContext` (see `doc/frontend/workflow.md` → "Never use setContext /
 * getContext"). All persistence is browser-gated — on the server every read
 * returns an empty list and every write is a no-op, mirroring `session.svelte`
 * and `clientCache.ts` so one user's history can never leak into another
 * user's SSR request.
 *
 * The store holds up to {@link MAX_STORED} entries globally (oldest evicted).
 * The dashboard renders the latest {@link MAX_PER_DOMAIN} entries that match
 * the active domain — see {@link getRecentDocuments}.
 */

const STORAGE_KEY = 'facet.recentDocuments';
/** Maximum entries kept in localStorage (across all domains). */
const MAX_STORED = 40;
/** Maximum entries shown per domain on the dashboard. */
const MAX_PER_DOMAIN = 12;

const isBrowser = typeof window !== 'undefined';

/** A single recently-viewed entry, persisted to localStorage. */
export interface RecentDocument {
	/** Projection id (the document's `meta.id`). */
	id: string;
	/** Domain segment of the qualified doctype (e.g. `"crm"`). */
	domain: string;
	/** Doctype label (e.g. `"Contact"`). Used for the show-page link. */
	doctype: string;
	/** Epoch milliseconds when the document was last opened. */
	ts: number;
}

/** In-memory reactive mirror of the persisted list. */
let documents: RecentDocument[] = $state(readFromStorage());

/** Reads the persisted list. Returns `[]` on the server or when parsing fails. */
function readFromStorage(): RecentDocument[] {
	if (!isBrowser) return [];
	try {
		const raw = window.localStorage.getItem(STORAGE_KEY);
		if (!raw) return [];
		const parsed = JSON.parse(raw);
		return Array.isArray(parsed) ? (parsed as RecentDocument[]) : [];
	} catch {
		return [];
	}
}

/** Persists the in-memory list. No-op on the server. */
function writeToStorage(list: RecentDocument[]): void {
	if (!isBrowser) return;
	documents = list;
	try {
		window.localStorage.setItem(STORAGE_KEY, JSON.stringify(list));
	} catch {
		/* storage disabled (private mode / quota) — the in-memory mirror still works */
	}
}

/**
 * Record that the user opened a document. Deduplicates by `entry.id` by moving
 * the existing entry to the front with a fresh timestamp; new entries are
 * prepended. The list is trimmed to {@link MAX_STORED} so localStorage stays
 * compact. No-op on the server and for entries without an `id`.
 *
 * @param entry  The document to record. Only `id`, `domain`, and `doctype` are
 *                persisted — the display label is resolved at render time so a
 *                renamed document shows under its current name. `ts` is set to
 *                `Date.now()` if absent.
 */
export function recordRecentDocument(
	entry: Pick<RecentDocument, 'id' | 'domain' | 'doctype'> & { ts?: number }
): void {
	if (!isBrowser || !entry.id) return;
	const record: RecentDocument = {
		id: entry.id,
		domain: entry.domain,
		doctype: entry.doctype,
		ts: entry.ts ?? Date.now()
	};
	const without = documents.filter((d) => d.id !== record.id);
	const next = [record, ...without].slice(0, MAX_STORED);
	writeToStorage(next);
}

/**
 * The recently-viewed entries for the given domain, newest first, capped at
 * {@link MAX_PER_DOMAIN}. Returns `[]` on the server.
 */
export function getRecentDocuments(domain: string): RecentDocument[] {
	if (!isBrowser) return [];
	return documents.filter((d) => d.domain === domain).slice(0, MAX_PER_DOMAIN);
}

/** Clears the entire list. Called on logout alongside
 *  `invalidateAllClientCaches` / `clearCounts` so the next login (possibly as
 *  a different user) starts with an empty history. */
export function clearRecentDocuments(): void {
	writeToStorage([]);
}

/**
 * Drop one entry by id. The command palette prunes a recently-viewed entry
 * whose label resolve failed with a definitive "gone" answer from the API
 * (404 past retention, 410 tombstone) — the row would otherwise render as a
 * raw id and 404 on activation (B-392). No-op on the server, for an empty id,
 * and when the id is already absent (no pointless localStorage write).
 */
export function removeRecentDocument(id: string): void {
	if (!isBrowser || !id) return;
	const next = documents.filter((d) => d.id !== id);
	if (next.length === documents.length) return;
	writeToStorage(next);
}

export const MAX_RECENT_PER_DOMAIN = MAX_PER_DOMAIN;
