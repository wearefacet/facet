// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import * as messages from '$lib/paraglide/messages';
import type { DoctypeDef, EnumValue, FieldDef } from '$lib/doctype/types.js';
import { channelLabel, humanizeLabel } from './auditDiff.js';

/**
 * Filter schema for the global audit log (`GET /Api/Audit`).
 *
 * The shared `FilterBar` is schema-aware — it reads a `DoctypeDef`'s fields
 * and their `operators` metadata. Audit records are not documents of a real
 * doctype, so this module authors the schema the bar renders: one field per
 * filterable `mutations` column, whose declared operators mirror exactly what
 * `Audit::List.build_column_filter` accepts (`src/audit/list.cr`):
 *
 * - `action`, `actioner_id`, `app`, `channel`, `kind`, `trace` — `eq` / `ne`
 *   (string columns).
 * - `domain`, `doc_type` — `eq` only (the backend serves no `ne` on the doc
 *   pins).
 * - `doc_type` values are qualified `domain.Doctype` keys — the bare
 *   `mutations.doc_type` column is ambiguous across domains, so a picked
 *   doctype pins domain and doctype at once (the backend splits the
 *   qualified value into the domain + doc_type conjunct).
 * - `emitted_at` — `gte` / `lte` (a range column; no equality operator).
 *
 * No field declares `match`: the audit backend has no substring search, so
 * the bar renders no search box and can never emit a key the backend would
 * silently drop. `kind` and `trace` are the wire names of the `cause_kind`
 * and `cause_trace` columns (the backend maps them).
 */

/** Mutation action vocabulary (`mutations.action`). */
export const AUDIT_ACTIONS = ['create', 'update', 'delete', 'snapshot'] as const;

/** Auth channel vocabulary — mirrors `Mutation::Channel` (`mutations.channel`). */
export const AUDIT_CHANNELS = [
	'session',
	'oauth_app',
	'app_api_key',
	'api_key',
	'mcp',
	'internal'
] as const;

/** Cause kind vocabulary — mirrors `Mutation::CauseKind` (`mutations.cause_kind`). */
export const AUDIT_CAUSE_KINDS = [
	'request',
	'action',
	'hook_event',
	'hook_schedule',
	'replication',
	'cascade',
	'rollback',
	'migration',
	'periodic_snapshot',
	'webhook_test',
	'assistant',
	'compaction',
	'seed'
] as const;

/** Enum values the host page injects from live sources (registry, app list). */
export interface AuditDynamicEnumValues {
	/** Registry domains — `core.DocType` projection ids. */
	domains: EnumValue[];
	/**
	 * Registry doctypes — qualified `domain.Doctype` keys. The bare
	 * `mutations.doc_type` column is ambiguous across domains, so the picker
	 * (and the wire value) carries the qualified form; the backend splits it
	 * into the domain + doc_type conjunct.
	 */
	doctypes: EnumValue[];
	/** `app.App` documents — key is the projection id, label the display name. */
	apps: EnumValue[];
}

/** Action labels — the same words the action badge uses. */
function actionValues(): EnumValue[] {
	const labels: Record<(typeof AUDIT_ACTIONS)[number], string> = {
		create: messages.common_created(),
		update: messages.common_updated(),
		delete: messages.common_deleted(),
		snapshot: messages.audit_action_snapshot()
	};
	return AUDIT_ACTIONS.map((a) => ({ key: a, label: labels[a] }));
}

/**
 * Build the audit filter schema. The dynamic enums start empty; the page
 * fills them from the `core.DocType` registry and the `app.App` list and
 * rebuilds the schema — the `FilterBar` re-renders its pickers reactively.
 */
export function auditFilterDoctype(dynamic?: Partial<AuditDynamicEnumValues>): DoctypeDef {
	const fields: FieldDef[] = [
		{
			key: 'action',
			type: 'enum',
			title: messages.audit_action_column(),
			operators: ['eq', 'ne'],
			values: actionValues()
		},
		{
			key: 'channel',
			type: 'enum',
			title: messages.audit_filter_channel_label(),
			operators: ['eq', 'ne'],
			// Wire values stay canonical (`session`); the label shows `facet` —
			// the session channel is the Facet web UI itself.
			values: AUDIT_CHANNELS.map((c) => ({ key: c, label: channelLabel(c) }))
		},
		{
			key: 'kind',
			type: 'enum',
			title: messages.audit_filter_kind_label(),
			operators: ['eq', 'ne'],
			values: AUDIT_CAUSE_KINDS.map((k) => ({ key: k, label: humanizeLabel(k) }))
		},
		{
			key: 'domain',
			type: 'enum',
			title: messages.audit_filter_domain_label(),
			operators: ['eq'],
			values: dynamic?.domains ?? []
		},
		{
			// Qualified `domain.Doctype` values (see `AuditDynamicEnumValues`):
			// one pick filters domain and doctype at the same time. `eq` only —
			// the backend pins the doc-identity fields to equality.
			key: 'doc_type',
			type: 'enum',
			title: messages.audit_filter_doctype_label(),
			operators: ['eq'],
			values: dynamic?.doctypes ?? []
		},
		{
			key: 'app',
			type: 'enum',
			title: messages.audit_filter_app_label(),
			operators: ['eq', 'ne'],
			values: dynamic?.apps ?? []
		},
		{
			// Reference to `iam.Account`: the bar renders a server-searched
			// combobox over the account's first `string` field (`email`, the one
			// field declaring `text_search`). Machine principals (`system`, …)
			// are not documents and cannot be picked — same as the API.
			key: 'actioner_id',
			type: 'reference',
			doctype: 'iam.Account',
			title: messages.audit_filter_actor_label(),
			operators: ['eq', 'ne']
		},
		{
			key: 'trace',
			type: 'string',
			title: messages.audit_filter_trace_label(),
			operators: ['eq']
		},
		{
			key: 'emitted_at',
			type: 'datetime',
			title: messages.audit_when_column(),
			operators: ['gte', 'lte']
		}
	];

	return {
		domain: 'core',
		doctype: 'Audit',
		description: 'Filter schema for the global audit log (not a stored doctype).',
		fields,
		children: [],
		actions: []
	};
}
