// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Pure derivations for the document history detail pane
 * (`HistoryDetailPane.svelte`): header labels, the `via` chip, the change
 * stats, child-row helpers, and actor-label resolution.
 *
 * No DOM access and no reactivity — the components call these from
 * `$derived`, effects, and the template.
 */

import type { Component } from 'svelte';
import {
	Bot,
	Clock,
	Code,
	Database,
	GitBranch,
	Globe,
	Monitor,
	Plug,
	RefreshCw,
	Server,
	Undo2,
	Webhook,
	Zap
} from '@lucide/svelte';
import type { DataDriver } from '$lib/datasource/driver.js';
import type { MutationRecord } from '$lib/datasource/types.js';
import * as messages from '$lib/paraglide/messages';
import {
	ACCOUNT_ID_PATTERN,
	channelLabel,
	hasCause,
	humanizeLabel,
	type ChangeEntry
} from './auditDiff.js';

// ── Detail header ──────────────────────────────────────────────
//
// Four rows, in order: what (action · doctype · label · version),
// who (actor · via channel/cause), when (full date · relative),
// ref (mutation id · copy · change stats).

/** The doctype of the mutation's target — the header's entity cell.
 * Empty when nothing is selected. */
export function detailEntity(mut: MutationRecord | null): string {
	return mut?.doc_type ?? '';
}

/** The target document's label: the record's `display_name` when the
 * response carries one (aggregate mode), else the page-provided label
 * for a parent row, else a short doc id. Empty when nothing is selected. */
export function detailLabel(
	mut: MutationRecord | null,
	includeChildren: boolean,
	parentDocType: string | null,
	documentLabel: string | null
): string {
	if (!mut) return '';
	return (
		mut.display_name ??
		(isChildRow(mut, includeChildren, parentDocType) ? null : documentLabel) ??
		childFallbackLabel(mut.doc_id)
	);
}

/** Icon for a cause kind — the notable provenance kinds get one; the
 * rest render as a text-only chip. */
export const CAUSE_ICONS: Record<string, Component> = {
	assistant: Bot,
	action: Zap,
	rollback: Undo2,
	cascade: GitBranch,
	hook_event: Webhook,
	hook_schedule: Clock,
	periodic_snapshot: Clock,
	replication: RefreshCw,
	migration: Database,
	webhook_test: Globe,
	seed: Database
};

/** Icon for an auth channel. */
export const CHANNEL_ICONS: Record<string, Component> = {
	session: Monitor,
	mcp: Plug,
	api_key: Code,
	app_api_key: Code,
	oauth_app: Globe,
	internal: Server
};

export interface ViaChip {
	/** `assistant` — LLM write (amber); `cause` — other provenance
	 * (accent); `chan` — plain auth channel (neutral). */
	tone: 'assistant' | 'cause' | 'chan';
	label: string;
	sub: string | null;
	icon: Component | null;
}

/** The `via <…>` chip: what actually carried the write. An action write
 * names the transport and rides the action name in the sub slot (`facet ·
 * confirm`); a plain request falls through to the auth channel, with the
 * elected acting role as the sub-label (the masked key tail wins on key
 * channels); the other cause kinds keep their humanized kind label.
 * `null` when nothing is selected or no chip applies. */
export function viaChip(mut: MutationRecord | null): ViaChip | null {
	if (!mut) return null;
	if (hasCause(mut)) {
		if (mut.cause_kind === 'action') {
			return {
				tone: 'cause',
				label: channelLabel(mut.channel),
				sub: mut.cause_name ?? null,
				icon: CHANNEL_ICONS[mut.channel] ?? null
			};
		}
		return {
			tone: mut.cause_kind === 'assistant' ? 'assistant' : 'cause',
			label: humanizeLabel(mut.cause_kind),
			sub: mut.cause_name ?? null,
			icon: CAUSE_ICONS[mut.cause_kind] ?? null
		};
	}
	if (!mut.channel) return null;
	const sub =
		mut.api_key != null
			? messages.audit_detail_key_sub({ mask: `…${mut.api_key.slice(-4)}` })
			: (mut.acting_role ?? null);
	return {
		tone: 'chan',
		label: channelLabel(mut.channel),
		sub,
		icon: CHANNEL_ICONS[mut.channel] ?? null
	};
}

export interface StatPart {
	kind: 'set' | 'patch' | 'unset' | 'redacted';
	label: string;
}

/** The ref row's change stats: counts per diff operation, `init`
 * entries (creates, snapshots) counted as `set`, `redacted` entries
 * counted separately. */
export function changeStats(changes: ChangeEntry[]): StatPart[] {
	let set = 0;
	let patch = 0;
	let unset = 0;
	let redacted = 0;
	for (const c of changes) {
		if (c.kind === 'set' || c.kind === 'init') set += 1;
		else if (c.kind === 'patch') patch += 1;
		else if (c.kind === 'unset') unset += 1;
		else if (c.kind === 'redacted') redacted += 1;
	}
	const out: StatPart[] = [];
	if (set > 0) out.push({ kind: 'set', label: messages.audit_summary_set({ count: set }) });
	if (patch > 0)
		out.push({
			kind: 'patch',
			label:
				patch === 1
					? messages.audit_summary_patch_singular({ count: patch })
					: messages.audit_summary_patch_plural({ count: patch })
		});
	if (unset > 0) out.push({ kind: 'unset', label: messages.audit_summary_unset({ count: unset }) });
	if (redacted > 0)
		out.push({
			kind: 'redacted',
			label: messages.audit_summary_redacted({ count: redacted })
		});
	return out;
}

// ── Child rows ──────────────────────────────────────────────────────

/** A row belongs to a child document when the aggregate mode is on and
 * its doctype differs from the parent's. */
export function isChildRow(
	m: MutationRecord,
	includeChildren: boolean,
	parentDocType: string | null
): boolean {
	return includeChildren && parentDocType != null && m.doc_type !== parentDocType;
}

/** Fallback label for a child row whose `display_name` is missing. */
export function childFallbackLabel(docId: string): string {
	return docId.length > 12 ? docId.slice(0, 12) + '…' : docId;
}

// ── Actor labels ────────────────────────────────────────────────────
//
// `actioner_id` is a bare account ULID for mutations made by a signed-in
// account, and a readable principal name (`system`, `system:rollback`, …)
// for machine callers. The timeline shows the account display name and
// keeps the raw value otherwise.

/** Resolved display name for an actioner, or the raw id. */
export function actorLabel(labels: Record<string, string>, id: string): string {
	return labels[id] ?? id;
}

/**
 * Resolve the display label for one actioner through the driver with one
 * `iam.Account` show. The label chain matches the audit page's actor
 * search: `display_name` on the meta, then `name`, then `email`
 * on the content. `null` keeps the bare id visible — for a non-account
 * id, a failed lookup (no grant, unknown id), or no readable label.
 */
export async function resolveActorLabel(d: DataDriver, id: string): Promise<string | null> {
	if (!ACCOUNT_ID_PATTERN.test(id)) return null;
	try {
		const res = await d.domain('iam').doctype('Account').doc(id).show();
		const content = res.data as Record<string, unknown>;
		return (
			res.meta.display_name ??
			(typeof content.name === 'string' && content.name.length > 0 ? content.name : undefined) ??
			(typeof content.email === 'string' && content.email.length > 0 ? content.email : undefined) ??
			null
		);
	} catch {
		return null;
	}
}
