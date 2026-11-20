// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Domain security — pure model rules for the domain editor.
 *
 * The `core.Domain` document carries replication `grants` and RBAC
 * `context_sets`. This module holds the rules over that data (wildcard
 * grants, field pruning on a doctype switch, the array working copies of
 * the `context_sets` map) so the Vitest `server` project can test them in
 * plain Node. Paraglide `m.*` in a pure module follows the `loginFlow.ts`
 * precedent.
 */
import * as m from '$lib/paraglide/messages';

/** One replication grant: what a consumer may read from a source doctype. */
export interface Grant {
	to: string;
	doctype: string;
	fields: string[] | string; // string[] of names, or the "*" wildcard
}

/** The editable subset of the `core.Domain` document content. */
export interface DomainDoc {
	/** Human display label, shown by the interface instead of the name. */
	label?: string;
	name?: string;
	description?: string;
	color?: string;
	draft?: boolean;
	source_domain?: string;
	grants?: Grant[];
	context_sets?: Record<string, { from: string; select: string; where: Record<string, string> }>;
}

/** Content of a `core.DomainEditor` document — one (account, domain) grant
 *  of domain-definition editing rights. The rows are separate admin-managed
 *  documents, not part of the `core.Domain` content. */
export interface DomainEditorContent {
	/** Qualified `iam.Account.<id>` reference to the granted account. */
	account?: string;
	/** The `core.Domain` row id the grant targets — the live slug (`crm`) or
	 *  the draft id (`_abc123`). */
	domain?: string;
}

/** One `where` condition of a context set, as a flat `{key, value}` pair. */
export interface WhereEntry {
	key: string;
	value: string;
}

/** Working-copy row of a context set. The stored document holds them as a
 *  map keyed by name; the editor edits an array (add/remove/reorder rows,
 *  rename keys without focus loss). `composeContextSets` is the inverse. */
export interface ContextSetRow {
	name: string;
	from: string;
	select: string;
	where: WhereEntry[];
}

/** Whether a grant grants all fields (the `"*"` wildcard). */
export function isWildcard(grant: Grant): boolean {
	return typeof grant.fields === 'string';
}

/** A grant's `fields` is `string[]` (explicit names) or `"*"` (wildcard).
 *  The editor's "Everything" checkbox keeps the two mutually exclusive, so
 *  this only fires for data loaded through other paths. Surfaced inline. */
export function wildcardFieldsError(grant: Grant): string | undefined {
	if (Array.isArray(grant.fields) && grant.fields.includes('*') && grant.fields.length > 1) {
		return m.configure_domains_grant_wildcard_error();
	}
	return undefined;
}

/** Field-key options for a grant, derived from the selected source doctype's
 *  schema. Empty until a doctype is chosen. */
export function grantFieldOptions(
	defs: { doctype: string; fields: { key: string }[] }[],
	grant: Grant
): { value: string; label: string }[] {
	if (!grant.doctype) return [];
	const def = defs.find((d) => d.doctype === grant.doctype);
	return (def?.fields ?? []).map((f) => ({ value: f.key, label: f.key }));
}

/** Drop selected field names that no longer exist on the grant's source
 *  doctype schema. The core of the editor's doctype switch: survivors keep
 *  their order. A wildcard grant passes through untouched. */
export function pruneGrantFields(grant: Grant, options: { value: string; label: string }[]): void {
	if (Array.isArray(grant.fields)) {
		const keys = new Set(options.map((o) => o.value));
		grant.fields = grant.fields.filter((f) => keys.has(f));
	}
}

/** Build the working-copy rows of context sets from the map stored on the
 *  domain document. Missing definition parts fall back to empty values so
 *  the editor can render and mutate each row without null-checks. */
export function contextSetRowsFromMap(map: DomainDoc['context_sets']): ContextSetRow[] {
	return Object.entries(map ?? {}).map(([name, def]) => ({
		name,
		from: def?.from ?? '',
		select: def?.select ?? '',
		where: Object.entries(def?.where ?? {}).map(([k, v]) => ({ key: k, value: v }))
	}));
}

/** Rebuild the `context_sets` map shape the backend expects from the
 *  working-copy rows. Rows without a name and `where` entries without a key
 *  are dropped. Called on save; the caller assigns the result to the domain
 *  document. */
export function composeContextSets(rows: ContextSetRow[]): NonNullable<DomainDoc['context_sets']> {
	const next: NonNullable<DomainDoc['context_sets']> = {};
	for (const row of rows) {
		if (!row.name) continue;
		const where: Record<string, string> = {};
		for (const entry of row.where) {
			if (entry.key) where[entry.key] = entry.value;
		}
		next[row.name] = { from: row.from, select: row.select, where };
	}
	return next;
}
