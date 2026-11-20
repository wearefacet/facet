// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { error } from '@sveltejs/kit';
import type { PageLoad } from './$types';
import { DocumentDataDriver } from '$lib/datasource/DocumentDriver';
import { parseDoctypeDef, type DoctypeDef } from '$lib/doctype/types.js';
import * as m from '$lib/paraglide/messages';

/**
 * Loads a single document's metadata for the `/{domain}/{doctype}/{id}/history`
 * audit route. We don't fetch the full document content here — the History
 * component only needs the `DocumentRef` (built from the driver + doc id) to
 * call `history()` and `rollback()`. We do resolve the doctype def + the
 * display name/version so the page header can mirror the show page.
 */
export const load: PageLoad = async ({ params, fetch }) => {
	const domain = params.domain;
	const doctypeLabel = decodeURIComponent(params.doctype);
	const docId = params.id;

	const driver = new DocumentDataDriver('', fetch);

	const result = await driver.domain('core').doctype('DocType').list({ items: 500 });
	const match = result.data.find((item) => {
		return (
			item.data.domain === domain && (item.data.doctype as string | undefined) === doctypeLabel
		);
	});

	if (!match) {
		throw error(404, m.errors_doctype_not_found({ name: `${domain}.${doctypeLabel}` }));
	}

	const def = parseDoctypeDef(match.data as Record<string, unknown>);

	// Fetch the document so the header can show its display name + version.
	// Tombstoned or RBAC-restricted docs still have a history trail — we leave
	// the header fields undefined in that case and let History render the
	// mutations list directly.
	let displayName: string | undefined;
	let version: number | undefined;
	try {
		const doc = await driver.domain(domain).doctype(doctypeLabel).doc(docId).show();
		displayName = doc.meta.display_name ?? undefined;
		version = doc.meta.version ?? undefined;
	} catch {
		/* fall through with undefined header fields */
	}

	return {
		def: def as DoctypeDef,
		qualifiedName: `${domain}.${doctypeLabel}`,
		docId,
		displayName,
		version,
		driver
	};
};
