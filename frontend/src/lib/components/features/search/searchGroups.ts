// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Palette item assembly — a pure module.
 *
 * Turns the nav model, the recently-viewed store, the record-search rows,
 * and the host command list into the four ordered palette groups (Navigate,
 * Recent, Records, Actions), applies the instant local filter, and drops
 * groups that hold no rows. No runes, no Svelte — Vitest covers it directly.
 *
 * Activation is data, not behaviour: each entry carries the target segments
 * (`domain` / `doctype` / `id`) and the component turns them into
 * `goto(resolve(...))` calls, keeping this module free of the router.
 */

import { flattenNavDoctypes, type NavDomain, type NavDoctype } from '$lib/navTypes';
import type { RecentDocument } from '$lib/recentDocuments.svelte';
import * as m from '$lib/paraglide/messages';
import type { RecordEntry, SearchScope } from './searchRecords.js';

/** A host-supplied action the palette renders in the Actions group. */
export interface PaletteCommand {
	/** Stable id — also the row key suffix. */
	id: string;
	/** Resolved user-facing label. */
	label: string;
	/** Optional category hint, shown as the row's right-side tag. */
	group?: string;
	/** Optional Lucide icon name (kebab-case), rendered as the doctype mark;
	 *  a command without one renders the signature diamond. */
	icon?: string;
	/** Runs the action. The palette closes after it returns. */
	run: () => void;
}

/** What a row activates to. */
export type PaletteEntryKind = 'domain' | 'doctype' | 'recent' | 'record' | 'escalate' | 'action';

/** One selectable palette row. */
export interface PaletteEntry {
	/** Unique DOM id — the row's key. */
	key: string;
	kind: PaletteEntryKind;
	/** Primary label; the local filter matches this. */
	label: string;
	/** Secondary line under the label (e.g. the matched child of a record). */
	subtitle?: string;
	/** Navigation target segments; kind-dependent. */
	domain?: string;
	doctype?: string;
	id?: string;
	/** Doctype mark tint + icon, resolved from the nav model. */
	color?: string | null;
	icon?: string | null;
	/** Right-aligned mono tag (qualified doctype, root doctype, scope hint). */
	tag?: string;
	/** The host command, for `kind: 'action'`. */
	command?: PaletteCommand;
	/** The query to re-run app-wide, for `kind: 'escalate'`. */
	query?: string;
}

/** The four fixed groups, in render order. */
export type PaletteGroupId = 'navigate' | 'recent' | 'records' | 'actions';

export interface PaletteGroup {
	id: PaletteGroupId;
	entries: PaletteEntry[];
}

/** Everything the assembly needs; all inputs are already resolved. */
export interface AssemblePaletteInput {
	/** The live-domain nav model. Empty on the Configure shell — its Navigate
	 *  group stays empty and its command list carries the surface. */
	domains: NavDomain[];
	/** Active domain id, or `''` when none (Configure, builder landing). */
	activeDomain: string;
	/** Recently-viewed entries for the active domain, newest first. */
	recents: RecentDocument[];
	/** Resolved display labels keyed by document id; the id is the fallback. */
	recentLabels: Record<string, string>;
	/** Host command list for the Actions group. */
	commands: PaletteCommand[];
	/** Shaped record-search rows (see `searchRecords.ts`). */
	records: RecordEntry[];
	/** Current search scope; app-wide rows carry their domain in the tag. */
	scope: SearchScope;
	/** The live query — the escalation row echoes it. */
	query: string;
}

/** User-facing group labels, resolved from the message catalogue. */
export function paletteGroupLabel(id: PaletteGroupId): string {
	switch (id) {
		case 'navigate':
			return m.palette_group_navigate();
		case 'recent':
			return m.palette_group_recent();
		case 'records':
			return m.palette_group_records();
		case 'actions':
			return m.palette_group_actions();
	}
}

/** Assembles the ordered groups. Groups without rows are dropped. */
export function assemblePaletteGroups(input: AssemblePaletteInput): PaletteGroup[] {
	const groups: PaletteGroup[] = [];

	const navigate = buildNavigateEntries(input.domains, input.activeDomain);
	if (navigate.length > 0) groups.push({ id: 'navigate', entries: navigate });

	const recent = buildRecentEntries(input.recents, input.recentLabels, input.domains);
	if (recent.length > 0) groups.push({ id: 'recent', entries: recent });

	const records = buildRecordEntries(input.records, input.domains, input.scope, input.query);
	if (records.length > 0) groups.push({ id: 'records', entries: records });

	if (input.commands.length > 0) {
		groups.push({ id: 'actions', entries: buildActionEntries(input.commands) });
	}

	return groups;
}

/**
 * Applies the instant local filter — a case-insensitive substring match on
 * the label, no debounce. Records are server-matched and pass through;
 * every group left without rows is dropped.
 */
export function filterPaletteGroups(groups: PaletteGroup[], query: string): PaletteGroup[] {
	const q = query.trim().toLowerCase();
	if (!q) return groups;
	return groups
		.map((group) => {
			if (group.id === 'records') return group;
			return { ...group, entries: group.entries.filter((e) => e.label.toLowerCase().includes(q)) };
		})
		.filter((group) => group.entries.length > 0);
}

// ── Internals ──────────────────────────────────────────────────────────────

function findDoctype(domains: NavDomain[], qualified: string): NavDoctype | undefined {
	for (const domain of domains) {
		for (const dt of flattenNavDoctypes(domain.doctypes)) {
			if (dt.qualified === qualified) return dt;
		}
	}
	return undefined;
}

/**
 * Navigate: every domain of the nav model, then the active domain's
 * doctypes. Doctype rows navigate to the doctype table; their mark and tag
 * come straight from the nav model.
 */
function buildNavigateEntries(domains: NavDomain[], activeDomain: string): PaletteEntry[] {
	const entries: PaletteEntry[] = [];
	for (const domain of domains) {
		entries.push({
			key: `palette-domain-${domain.id}`,
			kind: 'domain',
			label: domain.label,
			domain: domain.id,
			color: domain.color
		});
	}
	const active = domains.find((d) => d.id === activeDomain);
	if (active) {
		for (const dt of flattenNavDoctypes(active.doctypes)) {
			entries.push({
				key: `palette-doctype-${dt.qualified}`,
				kind: 'doctype',
				label: dt.label,
				domain: active.id,
				doctype: dt.label,
				color: dt.color,
				icon: dt.icon ?? null,
				tag: dt.qualified
			});
		}
	}
	return entries;
}

/**
 * Recent: the active domain's recently-viewed documents, newest first.
 * Labels resolve at render time (the store keeps only ids) — the caller
 * passes the resolved map and the id stands in until a label lands.
 */
function buildRecentEntries(
	recents: RecentDocument[],
	recentLabels: Record<string, string>,
	domains: NavDomain[]
): PaletteEntry[] {
	return recents.map((entry) => {
		const dt = findDoctype(domains, `${entry.domain}.${entry.doctype}`);
		return {
			key: `palette-recent-${entry.id}`,
			kind: 'recent' as const,
			label: recentLabels[entry.id] ?? entry.id,
			domain: entry.domain,
			doctype: entry.doctype,
			id: entry.id,
			color: dt?.color ?? null,
			icon: dt?.icon ?? null
		};
	});
}

/**
 * Records: the shaped search rows, each marked with its root doctype. In
 * app-wide scope the domain joins the tag, so rows from other domains read
 * qualified. In domain scope a trailing escalation row re-runs the query
 * app-wide — the `@` picker's escalation pattern.
 */
function buildRecordEntries(
	records: RecordEntry[],
	domains: NavDomain[],
	scope: SearchScope,
	query: string
): PaletteEntry[] {
	const entries: PaletteEntry[] = records.map((record) => {
		const dt = findDoctype(domains, `${record.domain}.${record.doctype}`);
		return {
			key: `palette-record-${record.key}`,
			kind: 'record' as const,
			label: record.label,
			subtitle: record.subtitle ?? undefined,
			domain: record.domain,
			doctype: record.doctype,
			id: record.id,
			color: dt?.color ?? null,
			icon: dt?.icon ?? null,
			tag: scope === 'app' ? `${record.domain} · ${record.doctype}` : record.doctype
		};
	});
	// The escalation row is the only path to a cross-domain hit, so it
	// renders even when the active-domain search found nothing.
	if (scope === 'domain') {
		entries.push({
			key: 'palette-escalate',
			kind: 'escalate',
			label: m.palette_escalate({ query: query.trim() }),
			query
		});
	}
	return entries;
}

/** Actions: the host command list, in the order the host supplied. */
function buildActionEntries(commands: PaletteCommand[]): PaletteEntry[] {
	return commands.map((command) => ({
		key: `palette-action-${command.id}`,
		kind: 'action',
		label: command.label,
		command,
		icon: command.icon ?? null,
		tag: command.group
	}));
}
