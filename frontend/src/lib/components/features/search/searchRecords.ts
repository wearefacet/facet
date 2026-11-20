// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * The record-search adapter for the command palette.
 *
 * One debounced call to the backend search endpoint per typing burst
 * (`GET /Api/{domain}/search` for the active-domain scope, `GET /Api/search`
 * for the app-wide scope), with the same fetch path DataSources use —
 * `apiFetch` — so token refresh, preview-session tokens, and 401 recovery
 * behave like every other API call. The backend contract (see
 * `doc/backend/search.md`): `{ data: per-doctype groups, meta }` — each
 * group carries `domain`/`doctype` and its hits inherit them; every hit is
 * anchored to its aggregate root.
 *
 * This module holds no runes and no Svelte. The transport is injectable so
 * Vitest and stories stub the network; the component mounts its adapter
 * without one, so a module-level seam backs the storybook tests.
 */

import { apiFetch } from '$lib/session.svelte';

/** Which set of domains the search covers. */
export type SearchScope = 'domain' | 'app';

/** A fetch-like function — the native `fetch` or a test stub. */
export type SearchFetch = typeof fetch;

/**
 * One search result. Always anchored to its aggregate root. The wire
 * contract carries `domain`/`doctype` on the per-doctype group only — a hit
 * never repeats them, and the shaper inherits the group's values.
 */
export interface SearchHit {
	/** Projection id of the matched document. */
	id: string;
	/** Display label of the matched document. */
	display_name: string | null;
	/** Server-side relevance rank (higher is better; groups arrive ranked). */
	rank: number;
	/** Doctype of the aggregate root. Equals the group's doctype for a root hit. */
	root_doctype: string;
	/** Projection id of the aggregate root. Equals `id` for a root hit. */
	root_id: string;
	/** Display label of the aggregate root. */
	root_display_name: string;
	/** Label of the matched child; `null` when the hit is the root itself. */
	child_label: string | null;
}

/** One per-doctype group of the search response, in rank order. */
export interface SearchDoctypeGroup {
	domain: string;
	doctype: string;
	hits: SearchHit[];
}

/** The search endpoint response — the standard envelope. */
export interface SearchResponse {
	data: SearchDoctypeGroup[];
	meta: { q: string; count: number; scope: SearchScope };
}

/** One palette row produced from the response. One row per root anchor. */
export interface RecordEntry {
	/** Stable row key — domain, root doctype, and root id. */
	key: string;
	/** Domain the root lives in. */
	domain: string;
	/** Root doctype — the URL segment to navigate to. */
	doctype: string;
	/** Root id. */
	id: string;
	/** Root display label. */
	label: string;
	/** `"ChildDoctype · child label"` from the top-ranked child, or `null`. */
	subtitle: string | null;
}

/** Query length the server and the client both require before a search runs. */
export const SEARCH_MIN_QUERY_LENGTH = 2;
/** Debounce window; one request per burst of typing. */
export const SEARCH_DEBOUNCE_MS = 250;

/** Builds the endpoint URL for a query at the given scope. */
export function buildSearchUrl(q: string, scope: SearchScope, activeDomain: string): string {
	const term = encodeURIComponent(q);
	return scope === 'app' ? `/Api/search?q=${term}` : `/Api/${activeDomain}/search?q=${term}`;
}

/**
 * Shapes the response into flat rows. Child hits collapse into their root:
 * one entry per root anchor, labelled with the root's display name, with the
 * top-ranked child carried as the subtitle. In app-wide scope the active
 * domain's groups lead — a stable sort that keeps rank order otherwise; the
 * client knows the active domain, the server cannot.
 */
export function shapeSearchResponse(resp: SearchResponse, activeDomain: string): RecordEntry[] {
	const groups = [...(resp.data ?? [])].sort((a, b) => {
		const aActive = a.domain === activeDomain ? 0 : 1;
		const bActive = b.domain === activeDomain ? 0 : 1;
		return aActive - bActive;
	});

	interface Slot {
		domain: string;
		rootDoctype: string;
		rootId: string;
		label: string;
		child: { doctype: string; label: string } | null;
	}

	const byRoot = new Map<string, Slot>();
	const order: string[] = [];
	for (const group of groups) {
		// The wire contract carries `domain`/`doctype` at group level only. A
		// group without both cannot anchor a row to a page the app can open,
		// so its hits are dropped — a degraded group never throws here.
		const domain = typeof group.domain === 'string' ? group.domain : '';
		const doctype = typeof group.doctype === 'string' ? group.doctype : '';
		if (!domain || !doctype) continue;
		for (const hit of group.hits ?? []) {
			const rootDoctype = hit.root_doctype ?? doctype;
			const rootId = hit.root_id ?? hit.id;
			const key = `${domain}.${rootDoctype}.${rootId}`;
			let slot = byRoot.get(key);
			if (!slot) {
				slot = {
					domain,
					rootDoctype,
					rootId,
					label: hit.root_display_name ?? hit.display_name,
					child: null
				};
				byRoot.set(key, slot);
				order.push(key);
			}
			// First child hit in rank order wins the subtitle slot.
			if (hit.child_label && !slot.child) {
				slot.child = { doctype, label: hit.child_label };
			}
		}
	}

	return order.map((key) => {
		const slot = byRoot.get(key)!;
		return {
			key,
			domain: slot.domain,
			doctype: slot.rootDoctype,
			id: slot.rootId,
			label: slot.label,
			subtitle: slot.child ? `${slot.child.doctype} · ${slot.child.label}` : null
		};
	});
}

/** Result and transport hooks for a record-search adapter. */
export interface RecordSearchHandlers {
	/** Called with the latest rows after each settled burst. An empty array
	 *  clears the group (below the length gate, on failure, or on reset). */
	onResults: (entries: RecordEntry[]) => void;
	/** Optional transport override; the module-level seam applies otherwise. */
	transport?: SearchFetch;
}

/** The debounced search adapter the palette drives. */
export interface RecordSearch {
	/**
	 * Schedules a search. Short queries (below the length gate) drop the
	 * pending work and clear the results at once; longer queries wait out
	 * the debounce, so one burst of typing issues one request.
	 */
	query(q: string, scope: SearchScope, activeDomain: string): void;
	/** Drops the pending work and clears the results — used when the palette closes. */
	reset(): void;
}

// Module-level transport seam. The palette owns its adapter instance and
// exports no transport prop, so component tests and stories route the
// adapter through here instead.
let transportOverride: SearchFetch | null = null;

/**
 * Routes every search through the given transport until cleared with `null`.
 * Vitest and the storybook plays use this to stub the endpoint.
 */
export function setRecordSearchTransport(transport: SearchFetch | null): void {
	transportOverride = transport;
}

/**
 * Creates the palette's record-search adapter. A sequence counter drops
 * stale responses — only the most recently issued request may write
 * results (the `iconSearchSeq` pattern). A failed request silently clears
 * the rows: the records group vanishes, the other palette groups stay
 * usable, and no error state exists.
 */
export function createRecordSearch(handlers: RecordSearchHandlers): RecordSearch {
	let seq = 0;
	let timer: ReturnType<typeof setTimeout> | null = null;

	function clearPending(): void {
		if (timer !== null) {
			clearTimeout(timer);
			timer = null;
		}
	}

	async function run(q: string, scope: SearchScope, activeDomain: string): Promise<void> {
		const my = ++seq;
		try {
			const transport = handlers.transport ?? transportOverride ?? undefined;
			const res = await apiFetch(
				buildSearchUrl(q, scope, activeDomain),
				{ headers: { Accept: 'application/json' }, credentials: 'include' },
				transport ? { fetch: transport } : undefined
			);
			if (my !== seq) return; // a newer burst superseded this one
			if (!res.ok) {
				handlers.onResults([]);
				return;
			}
			const body = (await res.json()) as SearchResponse;
			if (my !== seq) return;
			handlers.onResults(shapeSearchResponse(body, activeDomain));
		} catch {
			// A failed request drops the records group silently — no error state.
			if (my === seq) handlers.onResults([]);
		}
	}

	return {
		query(q, scope, activeDomain) {
			clearPending();
			const trimmed = q.trim();
			if (trimmed.length < SEARCH_MIN_QUERY_LENGTH) {
				seq += 1; // drop any in-flight response
				handlers.onResults([]);
				return;
			}
			timer = setTimeout(() => {
				timer = null;
				void run(trimmed, scope, activeDomain);
			}, SEARCH_DEBOUNCE_MS);
		},
		reset() {
			clearPending();
			seq += 1;
			handlers.onResults([]);
		}
	};
}
