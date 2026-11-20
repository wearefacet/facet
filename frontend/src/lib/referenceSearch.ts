// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Reference search — the pure shaping layer between the picker and the
 * backend search endpoints, plus the default sources bundle.
 *
 * The backend search engine (`doc/backend/search.md`) already fans out over
 * every readable searchable doctype of a scope and enforces RBAC per
 * doctype, so the picker issues one call per mode instead of a client-side
 * per-doctype fan-out: `GET /Api/{domain}/search` for the current domain,
 * `GET /Api/search` for the explicit all-domains escalation. This module
 * shapes the response into per-doctype groups, pulls account hits out (the
 * pinned People group owns accounts — the dedicated `searchAccounts` source
 * covers accounts in every scope, including single-domain scopes that
 * cannot see the `iam` domain), and provides the debounced query
 * dispatcher the picker drives.
 *
 * Everything here is pure except the default sources factory, which exists
 * so `Markdown.svelte` stays driver-free: the primitive takes an injectable
 * `sources` bundle, and stories pass synthetic ones (the `onupload`
 * precedent).
 */

import { apiFetch } from './session.svelte';
import { getRecentDocuments, type RecentDocument } from './recentDocuments.svelte';
import { searchAccounts, type MentionCandidate } from './mentions.js';
import {
	listDoctypes,
	searchDoctype,
	resolveChipLabel,
	type DocCandidate,
	type DocTypeOption,
	type ChipResolution
} from './docrefs.js';

/** Query length the server requires before a search runs — it answers
 *  shorter terms with an empty result, so the client gates the same way. */
export const SEARCH_MIN_QUERY_LENGTH = 2;
/** Per-doctype hit cap the server applies. A group at the cap offers the
 *  "more in …" row that enters scoped mode. */
export const PER_DOCTYPE_CAP = 5;
/** Debounce window for query-driven fetches. */
export const PICKER_DEBOUNCE_MS = 200;

/** One search hit of the backend response (doc/backend/search.md → Contract).
 *  The wire contract carries `domain`/`doctype` on the per-doctype group
 *  only — a hit never repeats them, and the shaper inherits the group's
 *  values. */
export interface SearchHitLike {
	id: string;
	display_name: string | null;
	root_doctype: string;
	root_id: string;
	root_display_name: string;
	child_label: string | null;
}

/** The search endpoint response — the standard envelope. */
export interface SearchResponseLike {
	data: { domain: string; doctype: string; hits: SearchHitLike[] }[] | null;
}

/** One selectable document row of the picker. */
export interface PickerEntry {
	/** Stable row key — domain, root doctype, and root id. */
	key: string;
	domain: string;
	/** Root doctype — child hits collapse into their aggregate root. */
	doctype: string;
	id: string;
	label: string;
	/** `"ChildDoctype · child label"` from the top-ranked child, or `null`. */
	subtitle: string | null;
}

/** One per-doctype result group, in first-hit rank order. */
export interface PickerGroup {
	/** Qualified `domain.Doctype`. */
	key: string;
	domain: string;
	doctype: string;
	entries: PickerEntry[];
	/** True when the group sits at the server's per-doctype cap — more
	 *  records may exist beyond it. */
	atCap: boolean;
}

/** The shaped result of one backend search call. */
export interface ShapedSearch {
	/** Account hits, root-collapsed and deduplicated. The caller renders
	 *  them as the pinned People group. */
	accounts: PickerEntry[];
	/** Per-doctype groups, active domain first, then rank order. */
	groups: PickerGroup[];
}

/** The injectable data-source bundle of the reference picker. */
export interface PickerSources {
	/** The pinned People group — mention candidates. */
	searchAccounts?: (q: string) => Promise<MentionCandidate[]>;
	/** Readable doctypes for "Filter by type" and scoped mode. */
	listDoctypes?: () => Promise<DocTypeOption[]>;
	/** One doctype's records for scoped mode (empty query browses). */
	searchDoctype?: (qualified: string, q: string) => Promise<DocCandidate[]>;
	/** The current domain's search — one server-side fan-out call. */
	searchDomain?: (q: string) => Promise<PickerGroup[]>;
	/** The app-wide escalation — one server-side fan-out call. */
	searchAllDomains?: (q: string) => Promise<PickerGroup[]>;
	/** Recent documents of the current domain for the empty state. */
	recentDocuments?: () => RecentDocument[];
	/** Live chip label resolver with status inspection. */
	resolveLabel?: (domain: string, doctype: string, id: string) => Promise<ChipResolution>;
}

/** Builds the search endpoint URL for a query at the given scope. */
export function pickerSearchUrl(q: string, scope: 'domain' | 'app', activeDomain: string): string {
	const term = encodeURIComponent(q);
	return scope === 'app' ? `/Api/search?q=${term}` : `/Api/${activeDomain}/search?q=${term}`;
}

/**
 * Shapes a search response into the picker's groups. Child hits collapse
 * into their aggregate root (a reference must land on a page the app can
 * open); account hits are lifted out of the groups — the pinned People
 * group owns them, and in app scope the response would otherwise repeat
 * them. Group order is stable: the active domain first, then first-hit
 * rank order, so the list never reorders within one response.
 */
export function shapePickerSearch(resp: SearchResponseLike, activeDomain: string): ShapedSearch {
	interface Slot {
		entry: PickerEntry;
		child: { doctype: string; label: string } | null;
	}

	const byRoot = new Map<string, Slot>();
	for (const group of resp.data ?? []) {
		// The wire contract carries `domain`/`doctype` at group level only. A
		// group without both cannot anchor an entry to a page the app can
		// open, so its hits are dropped — a degraded group never throws here.
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
					entry: {
						key,
						domain,
						doctype: rootDoctype,
						id: rootId,
						label: hit.root_display_name ?? hit.display_name ?? rootId,
						subtitle: null
					},
					child: null
				};
				byRoot.set(key, slot);
			}
			if (hit.child_label && !slot.child) {
				slot.child = { doctype, label: hit.child_label };
			}
		}
	}

	const accounts: PickerEntry[] = [];
	const groupOrder: string[] = [];
	const byDoctype = new Map<string, PickerGroup>();
	for (const slot of byRoot.values()) {
		const { entry } = slot;
		if (slot.child) {
			entry.subtitle = `${slot.child.doctype} · ${slot.child.label}`;
		}
		if (entry.domain === 'iam' && entry.doctype === 'Account') {
			accounts.push(entry);
			continue;
		}
		let group = byDoctype.get(`${entry.domain}.${entry.doctype}`);
		if (!group) {
			group = {
				key: `${entry.domain}.${entry.doctype}`,
				domain: entry.domain,
				doctype: entry.doctype,
				entries: [],
				atCap: false
			};
			byDoctype.set(group.key, group);
			groupOrder.push(group.key);
		}
		group.entries.push(entry);
	}

	const groups = groupOrder
		.map((key) => byDoctype.get(key)!)
		.sort((a, b) => {
			const aActive = a.domain === activeDomain ? 0 : 1;
			const bActive = b.domain === activeDomain ? 0 : 1;
			return aActive - bActive;
		})
		.map((group) => ({ ...group, atCap: group.entries.length >= PER_DOCTYPE_CAP }));

	return { accounts, groups };
}

/** Fetches one search scope through `apiFetch` and shapes the response. */
export async function fetchPickerSearch(
	q: string,
	scope: 'domain' | 'app',
	activeDomain: string,
	fetchFn?: typeof fetch
): Promise<PickerGroup[]> {
	const res = await apiFetch(
		pickerSearchUrl(q, scope, activeDomain),
		{ headers: { Accept: 'application/json' }, credentials: 'include' },
		fetchFn ? { fetch: fetchFn } : undefined
	);
	if (!res.ok) return [];
	const body = (await res.json()) as SearchResponseLike;
	return shapePickerSearch(body, activeDomain).groups;
}

/**
 * Debounced query dispatcher with a monotonic sequence. `query` schedules
 * `run` after the debounce window; every call — scheduled or not — bumps
 * the sequence, so async completions compare against `currentSeq()` and
 * discard stale results on each keystroke.
 */
export function createQueryDispatcher(
	delayMs: number,
	run: (q: string, seq: number) => void
): {
	query(q: string): void;
	cancel(): void;
	currentSeq(): number;
} {
	let seq = 0;
	let timer: ReturnType<typeof setTimeout> | null = null;

	return {
		query(q: string) {
			const my = ++seq;
			if (timer !== null) clearTimeout(timer);
			timer = setTimeout(() => {
				timer = null;
				run(q, my);
			}, delayMs);
		},
		cancel() {
			seq += 1;
			if (timer !== null) {
				clearTimeout(timer);
				timer = null;
			}
		},
		currentSeq() {
			return seq;
		}
	};
}

/** The default (real-service) sources bundle for one domain context.
 *  Stories pass synthetic sources instead, so this path never runs there. */
export function createDefaultSources(domain: string, fetchFn?: typeof fetch): PickerSources {
	return {
		searchAccounts: (q) => searchAccounts(q, fetchFn),
		listDoctypes: () => listDoctypes(fetchFn),
		searchDoctype: (qualified, q) => searchDoctype(qualified, q, fetchFn),
		searchDomain: (q) =>
			domain ? fetchPickerSearch(q, 'domain', domain, fetchFn) : Promise.resolve([]),
		searchAllDomains: (q) => fetchPickerSearch(q, 'app', domain, fetchFn),
		recentDocuments: () => (domain ? getRecentDocuments(domain) : []),
		resolveLabel: (d, doctype, id) => resolveChipLabel(d, doctype, id, fetchFn)
	};
}
