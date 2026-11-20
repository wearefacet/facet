// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Domain grants — pure model rules for the grants tab and the publish
 * report.
 *
 * A `core.DomainGrant` document lives under the **producer** domain (its
 * `meta.parent_id` is the producer's domain id) and names one consumer
 * domain plus the resources (producer doctypes + field tags) the consumer
 * may read. `active` is the producer's acceptance state — document
 * callers can never write it; only the activate/deactivate routes set it.
 *
 * The tag vocabulary is free-form (D10): an untagged producer field
 * resolves to the `default` tag (D4), so a resource entry naming
 * `default` reaches every untagged field. This module holds the wire
 * types, the resource working-copy rows, the authoring checks the typed
 * schema cannot express, and the publish-ticket display rules so the
 * Vitest `server` project can test them in plain Node.
 */
import * as m from '$lib/paraglide/messages';

/** The tag an untagged producer field resolves to (D4). */
export const DEFAULT_TAG = 'default';

/** One resource entry of a grant — the granted doctype with its tag mask. */
export interface GrantResourceEntry {
	doctype: string;
	tags: string[];
}

/** Content of a `core.DomainGrant` document. */
export interface DomainGrantContent {
	/** Qualified `core.Domain.<id>` reference to the consumer domain. */
	consumer_domain?: string;
	/** One entry per producer doctype the consumer may read. */
	resources?: GrantResourceEntry[];
	/** Acceptance state. Read-only on the wire — the routes set it. */
	active?: boolean;
}

/** One edge of a publish ticket — the (doctype, tags) the consumer's
 *  published definition pulls from one producer doctype. */
export interface GrantTicketEdge {
	doctype: string;
	tags: string[];
}

/** One producer's publish-ticket outcome. All of the publish's edges into
 *  one producer fold into the same grant document, so the acceptance
 *  state is per ticket. Shape mirrors the backend publish response. */
export interface GrantTicket {
	producer: string;
	/** true — a new grant document was created; false — merged into an existing one. */
	filed: boolean;
	/** The grant's resulting active state. */
	active: boolean;
	/** true — an active grant was widened and dropped to inactive (D6 re-acceptance). */
	dropped: boolean;
	edges: GrantTicketEdge[];
}

/** The publish response's grant-ticket report. */
export interface PublishReport {
	domain: string;
	grant_tickets: GrantTicket[];
}

/** Bare domain id behind a qualified `core.Domain.<id>` reference (the bare
 *  form is accepted too — reference storage qualifies, hand-made rows may
 *  not). Empty input stays empty. */
export function grantDomainId(ref: string | undefined): string {
	if (!ref) return '';
	return ref.startsWith('core.Domain.') ? ref.slice('core.Domain.'.length) : ref;
}

/** Working-copy row of one resource entry — editable without focus loss. */
export interface ResourceRow {
	doctype: string;
	tags: string;
}

/** Builds the working-copy rows from the stored entries. Missing parts
 *  fall back to empty strings so the editor can render each row. */
export function resourceRowsFrom(entries: GrantResourceEntry[] | undefined): ResourceRow[] {
	return (entries ?? []).map((e) => ({
		doctype: e.doctype ?? '',
		tags: (e.tags ?? []).join(', ')
	}));
}

/** Rebuilds the stored entries from the working-copy rows. Rows without a
 *  doctype are dropped; tag strings split on commas, trimmed, and
 *  de-duplicated. Called on save. */
export function composeResourceRows(rows: ResourceRow[]): GrantResourceEntry[] {
	const out: GrantResourceEntry[] = [];
	for (const row of rows) {
		const doctype = row.doctype.trim();
		if (!doctype) continue;
		const tags: string[] = [];
		for (const raw of row.tags.split(',')) {
			const tag = raw.trim();
			if (tag && !tags.includes(tag)) tags.push(tag);
		}
		out.push({ doctype, tags });
	}
	return out;
}

/** Authoring check over the working-copy rows — the rules the typed field
 *  schema cannot express per row (mirrors the backend `Grants::Validator`):
 *  every kept row needs a doctype name and at least one non-empty tag.
 *  Returns the message for the first offending row, or `undefined`. */
export function resourceRowsError(rows: ResourceRow[]): string | undefined {
	for (const row of rows) {
		if (row.doctype.trim() && !composeResourceRows([row])[0]?.tags.length) {
			return m.configure_grants_row_tags_error();
		}
		if (!row.doctype.trim() && row.tags.trim()) {
			return m.configure_grants_row_doctype_error();
		}
	}
	return undefined;
}

/** True when the ticket's edges pull the producer's untagged fields — an
 *  edge naming `default` covers them (D4 trade-off: a new untagged field
 *  flows with no grant edit). */
export function ticketPullsUntagged(ticket: GrantTicket): boolean {
	return ticket.edges.some((edge) => edge.tags.includes(DEFAULT_TAG));
}

/** Tags already in use across a domain's doctype fields — the suggestion
 *  list for the field tag input. Sorted, de-duplicated. */
export function tagsInUse(defs: { fields: { tags?: string[] }[] }[]): string[] {
	const seen = new Set<string>();
	for (const def of defs) {
		for (const field of def.fields) {
			for (const tag of field.tags ?? []) seen.add(tag);
		}
	}
	return [...seen].sort((a, b) => a.localeCompare(b));
}
