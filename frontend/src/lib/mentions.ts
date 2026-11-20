// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Account mentions — the people half of the markdown `@` reference picker.
 *
 * A mention is an ordinary markdown link whose URL is the account's
 * canonical colon-form URN (`urn:facet:iam:Account:<id>`). The label keeps
 * the trigger glyph (`@Name`), so raw markdown — audit lists, source mode,
 * plain-text renderers — still reads as a mention. `Document::Links`
 * extracts the URN on save, and the seeded `core.Comment` hook notifies
 * mentioned accounts (see `doc/backend/notifications.md`).
 *
 * The stored form is the URN colon form — NOT the dotted reference form
 * (`iam.Account.<id>`) that `reference` field values use, and never the
 * `facet://` scheme: `DocURI.parse` and `Document::Links` accept the colon
 * form only. This module owns that asymmetry.
 */

import { DocumentDataSource } from './datasource/DocumentDataSource.js';
import { DataSourceError } from './datasource/types.js';

/** URN prefix of a live account reference — the colon storage form. */
export const ACCOUNT_URN_PREFIX = 'urn:facet:iam:Account:';

/** Rows the pinned People group shows — matches the search group cap. */
export const ACCOUNT_SEARCH_LIMIT = 5;

/** One account row of the picker's pinned People group. */
export interface MentionCandidate {
	/** Bare account id (the URN opaque part). */
	id: string;
	/** Display label — `meta.display_name`, falling back to the id. */
	name: string;
}

/** Builds the account URN for a bare account id. */
export function accountUrn(id: string): string {
	return `${ACCOUNT_URN_PREFIX}${id}`;
}

/**
 * Parses an account URN from a link href. Returns the bare account id, or
 * `null` for anything else — including state-pinned URNs (`…?state=…`),
 * which render as plain links, not chips.
 */
export function parseAccountUrn(href: string | null | undefined): string | null {
	if (!href || !href.startsWith(ACCOUNT_URN_PREFIX)) return null;
	const id = href.slice(ACCOUNT_URN_PREFIX.length);
	if (!id || id.includes('?')) return null;
	return id;
}

/**
 * The markdown link a picked mention inserts. The label carries the
 * trigger glyph so the stored source reads as a mention.
 */
export function mentionMarkdown(id: string, name: string): string {
	return `[@${name}](${accountUrn(id)})`;
}

/**
 * Searches accounts through the standard `iam.Account` list — the backend
 * `search` filter over the trigram corpus (`iam.Account` declares
 * `search: "{{ email }} {{ name }}"`). Every seeded non-anonymous
 * role can read accounts; a denied or failed request degrades to an empty
 * group, never an error — the same tolerance the comment surface shows for
 * unresolvable author labels.
 */
export async function searchAccounts(
	q: string,
	fetchFn?: typeof fetch
): Promise<MentionCandidate[]> {
	try {
		const ds = new DocumentDataSource('iam', 'Account', undefined, fetchFn);
		const res = await ds.list({ filters: { search: q }, items: ACCOUNT_SEARCH_LIMIT });
		return res.data.map(({ meta }) => ({ id: meta.id, name: meta.display_name ?? meta.id }));
	} catch (e) {
		if (e instanceof DataSourceError) return [];
		throw e;
	}
}
