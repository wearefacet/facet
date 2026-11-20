// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { MutationRecord } from '$lib/datasource/types.js';
import * as messages from '$lib/paraglide/messages';

export type ActionTone = 'ok' | 'info' | 'danger' | 'neutral';

export interface ActionVariant {
	tone: ActionTone;
	label: string;
}

const ACTION_VARIANTS: Record<string, ActionVariant> = {
	create: { tone: 'ok', label: messages.common_created() },
	update: { tone: 'info', label: messages.common_updated() },
	delete: { tone: 'danger', label: messages.common_deleted() },
	snapshot: { tone: 'neutral', label: messages.audit_action_snapshot() }
};

/**
 * Humanize a snake_case origin/event name into a Title Case label.
 * e.g. `promoted` → "Promoted", `document_approved` → "Document Approved".
 */
export function humanizeLabel(s: string): string {
	return s
		.split('_')
		.filter(Boolean)
		.map((p) => p.charAt(0).toUpperCase() + p.slice(1))
		.join(' ');
}

/**
 * Resolve the tone + label for a mutation. When the mutation carries a
 * `cause_event` (set by the backend for actions like `promote`, `convert`,
 * or rollbacks), that event — humanized — is used as the label so the
 * timeline reflects *what actually happened* rather than the generic action
 * bucket.
 */
export function actionVariant(m: MutationRecord): ActionVariant {
	const base = ACTION_VARIANTS[m.action] ?? { tone: 'neutral' as ActionTone, label: m.action };
	if (typeof m.cause_event === 'string' && m.cause_event.length > 0) {
		return { tone: base.tone, label: humanizeLabel(m.cause_event) };
	}
	return base;
}

/**
 * A normalized description of a single change made by a mutation.
 *
 * - `set` — a value was placed at `path` (`value` holds the new value).
 * - `patch` — a long string at `path` was edited with a line-based patch
 *   (`value` is undefined; `patch` is the raw diff object).
 * - `unset` — the key at `path` was removed.
 * - `init` — field was part of the initial content on a `create`.
 * - `removed` — field was present at creation but is part of an unset-style
 *   removal on `delete` (rare; only used when we want to surface it).
 * - `redacted` — the server hid the value at `path` before sending (field-tag
 *   visibility); the row shows a hidden chip instead of a value.
 */
export interface ChangeEntry {
	path: string;
	kind: 'set' | 'patch' | 'unset' | 'init' | 'redacted';
	value?: unknown;
	patch?: unknown;
}

/** Turn a backend path (string or array of segments) into a `/a/b/c` string. */
export function normalizePath(p: unknown): string {
	if (Array.isArray(p)) return '/' + p.map(String).join('/');
	if (typeof p === 'string') return p.startsWith('/') ? p : '/' + p;
	if (p == null) return '/';
	return '/' + String(p);
}

/** Pull the diff object out of an update mutation's arguments. */
function diffOf(m: MutationRecord): { set?: unknown[]; unset?: unknown[] } | undefined {
	const args = m.arguments as Record<string, unknown>;
	const diff = (args.diff ?? args) as { set?: unknown[]; unset?: unknown[] };
	return diff;
}

/** Normalized `/a/b` paths whose values the server removed from the row's
 * `arguments` before sending (field-tag visibility). Empty when the row
 * carries no `redacted` metadata. */
function redactedPaths(m: MutationRecord): Set<string> {
	if (!Array.isArray(m.redacted)) return new Set();
	return new Set(m.redacted.map((p) => normalizePath(p)));
}

/** Append a `redacted` entry for each hidden path the change list does not
 * cover yet — a value the server dropped from the payload entirely, or a
 * nested path hidden under a visible container. Paths already present (a
 * redacted set row, an unset row) stay untouched, so no entry duplicates. */
function appendRedacted(out: ChangeEntry[], redacted: Set<string>): void {
	for (const path of redacted) {
		if (!out.some((c) => c.path === path)) out.push({ path, kind: 'redacted' });
	}
}

/** Change entries for the content map of a `create` or `snapshot`. A field
 * the server hid renders as a `redacted` entry with no value; a hidden
 * nested path under a visible container appends its own entry. */
function contentChanges(content: unknown, redacted: Set<string>): ChangeEntry[] {
	const out: ChangeEntry[] = [];
	if (content && typeof content === 'object') {
		for (const [k, v] of Object.entries(content)) {
			const path = '/' + k;
			if (redacted.has(path)) {
				out.push({ path, kind: 'redacted' });
			} else {
				out.push({ path, kind: 'init', value: v });
			}
		}
	}
	appendRedacted(out, redacted);
	return out;
}

/**
 * Extract a normalized list of change entries from any mutation.
 *
 * Covers `create`, `update` (with `set` of `{path, value | patch}` and
 * `unset` of path arrays), `delete`, and `snapshot`. Custom-action updates
 * carry the same `arguments.diff` shape as a plain update, so they are
 * surfaced identically.
 *
 * The row's `redacted` metadata (paths the server hid from `arguments`)
 * renders as `redacted` entries: a matching `set`/`patch` op loses its
 * value, a create/snapshot field shows no value, and a hidden path no op
 * covers appends its own entry. An `unset` entry never gains a duplicate
 * redacted row.
 */
export function mutationChanges(m: MutationRecord): ChangeEntry[] {
	const args = m.arguments as Record<string, unknown>;

	switch (m.action) {
		case 'create':
			return contentChanges(args.content, redactedPaths(m));
		case 'update': {
			const diff = diffOf(m);
			if (!diff) return [];
			const redacted = redactedPaths(m);
			const out: ChangeEntry[] = [];
			if (Array.isArray(diff.set)) {
				for (const op of diff.set as Record<string, unknown>[]) {
					if (!op || typeof op !== 'object') continue;
					const path = normalizePath(op.path);
					if (redacted.has(path)) {
						out.push({ path, kind: 'redacted' });
					} else if (op.patch != null) {
						out.push({ path, kind: 'patch', patch: op.patch });
					} else if ('value' in op) {
						out.push({ path, kind: 'set', value: op.value });
					}
				}
			}
			if (Array.isArray(diff.unset)) {
				for (const p of diff.unset as unknown[]) {
					out.push({ path: normalizePath(p), kind: 'unset' });
				}
			}
			appendRedacted(out, redacted);
			return out;
		}
		case 'snapshot':
			return contentChanges(args.content, redactedPaths(m));
		case 'delete':
		default:
			return [];
	}
}

/**
 * Badge label for a change kind. The label currently equals the kind, but
 * the kind is a machine value (`set`/`patch`/`unset`/`init`) — route any
 * future wording change through here so both audit surfaces stay in step.
 */
export function kindLabel(kind: ChangeEntry['kind']): string {
	return kind;
}

/** Change entries group under one badge per kind, in this order: fields
 * added or initialized first, text patches next, removals last, hidden
 * (redacted) values at the end. */
const KIND_GROUP_ORDER: ChangeEntry['kind'][] = ['init', 'set', 'patch', 'unset', 'redacted'];

export interface ChangeGroup {
	kind: ChangeEntry['kind'];
	entries: ChangeEntry[];
}

/**
 * Group a mutation's change entries by kind so `ChangeList` renders one
 * badge per group instead of one badge per row. Groups with no entries are
 * dropped; the within-group order stays the diff's original order.
 */
export function groupChanges(changes: ChangeEntry[]): ChangeGroup[] {
	return KIND_GROUP_ORDER.map((kind) => ({
		kind,
		entries: changes.filter((c) => c.kind === kind)
	})).filter((g) => g.entries.length > 0);
}

/** A rendered value longer than this truncates; the full text moves to the
 * row's hover title. */
export const VALUE_PREVIEW_LIMIT = 1024;

/** Cut `text` at `limit` characters with a trailing ellipsis. */
export function truncateValue(text: string, limit: number = VALUE_PREVIEW_LIMIT): string {
	return text.length > limit ? text.slice(0, limit) + '…' : text;
}

/**
 * True when a mutation's cause kind carries provenance worth surfacing —
 * everything except the default `request` write (a plain edit through the
 * signed-in session). The document history shows a `via <kind>` badge for
 * the rest (`assistant`, `action`, `rollback`, `cascade`, …); the global
 * audit detail applies the same rule to its cause block.
 */
export function hasCause(m: Pick<MutationRecord, 'cause_kind'>): boolean {
	return m.cause_kind !== 'request';
}

/**
 * Display label for an auth channel. The `session` channel is the Facet web
 * UI itself — show it as `facet` (the wire value stays `session`, so filters
 * and the API are untouched). Other channels pass through verbatim.
 */
export function channelLabel(channel: string): string {
	return channel === 'session' ? 'facet' : channel;
}

/**
 * The timeline row's `via <…>` badge. An action write names the transport,
 * with the action name riding alongside (`facet · confirm` — the same rule
 * the detail pane's via chip applies); the other cause kinds keep the
 * humanized kind label with no sub.
 */
export function viaLine(m: MutationRecord): { label: string; sub: string | null } {
	if (m.cause_kind === 'action') {
		return { label: channelLabel(m.channel), sub: m.cause_name ?? null };
	}
	return { label: humanizeLabel(m.cause_kind), sub: null };
}

/** Bare `iam.Account` id shape — 26-char Crockford base32 ULID. */
export const ACCOUNT_ID_PATTERN = /^[0-9A-HJKMNP-TV-Z]{26}$/;

/**
 * True when an `actioner_id` names an `iam.Account` document — a bare ULID
 * (signed-in account) or a qualified `iam.Account.id` token. Anything else
 * is a machine principal (`system`, `system:rollback`, …) and must render
 * as plain text, not as an account capsule.
 */
export function isAccountActioner(id: string): boolean {
	return ACCOUNT_ID_PATTERN.test(id) || id.startsWith('iam.Account.');
}

/** A short human-readable summary line for a mutation. */
export function describeMutation(m: MutationRecord): string {
	const args = m.arguments as Record<string, unknown>;
	switch (m.action) {
		case 'create': {
			const content = args.content as Record<string, unknown> | undefined;
			if (!content) return messages.audit_summary_created();
			const keys = Object.keys(content);
			if (keys.length === 0) return messages.audit_summary_empty_doc();
			return keys.length === 1
				? messages.audit_summary_fields_singular({ count: keys.length })
				: messages.audit_summary_fields_plural({ count: keys.length });
		}
		case 'update': {
			const changes = mutationChanges(m);
			const sets = changes.filter((c) => c.kind === 'set').length;
			const patches = changes.filter((c) => c.kind === 'patch').length;
			const unsets = changes.filter((c) => c.kind === 'unset').length;
			const hidden = changes.filter((c) => c.kind === 'redacted').length;
			const parts: string[] = [];
			if (sets > 0) parts.push(messages.audit_summary_set({ count: sets }));
			if (patches > 0)
				parts.push(
					patches === 1
						? messages.audit_summary_patch_singular({ count: patches })
						: messages.audit_summary_patch_plural({ count: patches })
				);
			if (unsets > 0) parts.push(messages.audit_summary_unset({ count: unsets }));
			if (hidden > 0) parts.push(messages.audit_summary_redacted({ count: hidden }));
			return parts.length > 0 ? parts.join(' · ') : messages.audit_summary_no_changes();
		}
		case 'delete':
			return messages.audit_summary_deleted();
		case 'snapshot':
			return m.cause_kind === 'rollback'
				? messages.audit_summary_restored()
				: messages.audit_summary_snapshot();
		default:
			return m.action;
	}
}

/** Render a value for the inspector — never throws on JSON-unserializable input. */
export function formatValue(v: unknown): string {
	if (v == null) return '';
	if (typeof v === 'string') return v;
	try {
		return JSON.stringify(v, null, 2);
	} catch {
		return String(v);
	}
}

export function isScalar(v: unknown): boolean {
	return v == null || typeof v === 'string' || typeof v === 'number' || typeof v === 'boolean';
}

/**
 * Parse a mutation's `cause_source` (`domain.Doctype:id` — the document the
 * cause ran on) into its parts. Ids are opaque and may contain dots, so the
 * doctype/id split rides on the first colon and the domain/doctype split on
 * the first dot of the pre-colon segment.
 */
export function parseCauseSource(
	source: string
): { domain: string; doctype: string; id: string } | null {
	const colon = source.indexOf(':');
	if (colon < 1) return null;
	const qualified = source.slice(0, colon);
	const dot = qualified.indexOf('.');
	if (dot < 1) return null;
	return {
		domain: qualified.slice(0, dot),
		doctype: qualified.slice(dot + 1),
		id: source.slice(colon + 1)
	};
}
