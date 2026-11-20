// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { DocumentDataSource } from './datasource/DocumentDataSource';
import type { DocumentMeta } from './datasource/types';
import type { DoctypeCatalogueEntry } from './app/appTypes';
import { fallbackPlural } from './app/appGrantsMapping';

export type { DoctypeCatalogueEntry };

/**
 * A `core.Domain` list row. Only the draft flag is read: a doctype that
 * belongs to a draft domain is authoring work in progress, not a target an
 * app can be granted access to.
 */
type DomainContent = {
	draft?: boolean;
};

/**
 * A `core.DocType` list row projected into the catalogue entry shape.
 * Mirrors only the fields the grants picker reads; the full projection
 * (fields, children, migrations, script) is intentionally dropped to
 * keep the catalogue payload small.
 */
type DocTypeContent = {
	doctype: string;
	domain: string;
	description?: string;
	label?: string;
	icon?: string;
	color?: string;
	plural_label?: string;
	sensitive?: boolean;
	aggregate_root?: boolean;
	member_of?: string;
	actions?: Record<string, { label?: string; description?: string }>;
};

/**
 * Load the doctype catalogue from `/Api/core/DocType`. The list endpoint
 * returns the full document content (including the `actions` dictionary),
 * so one call surfaces every doctype — no per-doctype detail fetch is
 * needed. A second call lists `core.Domain` to learn which domains are
 * drafts (see below); the two run in parallel.
 *
 * **Draft domains are excluded.** A draft domain is schema authoring in
 * progress (the builder), not a live target: its doctypes may be renamed,
 * dropped, or never published, so a grant naming one could not be honoured.
 * The catalogue is therefore the union of the live domains the active role
 * can read on `core.DocType`.
 *
 * `fetchFn` is forwarded through the DataSource so SSR load functions
 * pass `event.fetch` and keep `apiFetch`'s token refresh active.
 */
export async function loadDoctypeCatalogue(
	fetchFn?: typeof fetch
): Promise<{ entries: DoctypeCatalogueEntry[]; metas: Record<string, DocumentMeta> }> {
	const domains = new DocumentDataSource<DomainContent>('core', 'Domain', undefined, fetchFn);
	const doctypes = new DocumentDataSource<DocTypeContent>('core', 'DocType', undefined, fetchFn);

	// Both reads are independent, so one round-trip each, in parallel. The
	// domain read is required: without it the draft flag is unknown and a
	// draft domain's doctypes would leak back into the picker.
	const [domainList, doctypeList] = await Promise.all([domains.list({}), doctypes.list({})]);

	const draftDomainIds = new Set(
		domainList.data.filter(({ data }) => data.draft === true).map(({ meta }) => meta.id)
	);
	const data = doctypeList.data.filter(({ data }) => !draftDomainIds.has(data.domain));

	const entries = data.map(({ data: content }) => {
		const qualified = `${content.domain}.${content.doctype}`;
		const namedActions = content.actions
			? Object.entries(content.actions).map(([name, def]) => ({
					name,
					label: def.label ?? name
				}))
			: undefined;
		// The parent target is the qualified name of the doctype this one is
		// a member of. `member_of` is a bare CamelCase name within the same
		// domain, so we qualify it. Aggregate roots (or anything without a
		// `member_of`) have no parent.
		const parentTarget =
			content.member_of && !content.aggregate_root
				? `${content.domain}.${content.member_of}`
				: undefined;
		return {
			target: qualified,
			label: content.label?.trim() || content.doctype,
			description: content.description ?? '',
			domain: content.domain,
			namedActions: namedActions && namedActions.length > 0 ? namedActions : undefined,
			pluralLabel: content.plural_label?.trim() || fallbackPlural(qualified),
			sensitive: content.sensitive === true ? true : undefined,
			parentTarget,
			// Visual identity for pickers and reference chips. An empty icon
			// string (the field allows it) maps to undefined.
			icon: content.icon?.trim() || undefined,
			color: content.color?.trim() || undefined
		};
	});

	const metas: Record<string, DocumentMeta> = {};
	for (const { data: content, meta } of data) {
		metas[`${content.domain}.${content.doctype}`] = meta;
	}

	return { entries, metas };
}
