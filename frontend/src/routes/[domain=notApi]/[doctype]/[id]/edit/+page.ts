// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { PageLoad } from './$types';
import { buildDriver, resolveDoctype, rethrowLoadError } from '$lib/doctype/loadDoctypeDef.js';
import { loadDoctypeViewByKind, type LoadedView } from '$lib/doctype/loadDocumentView.js';
import type { DocumentResponse } from '$lib/datasource/types.js';
import * as m from '$lib/paraglide/messages';

/**
 * Loads a single document plus its `kind: form` DocumentView for the edit route.
 *
 * Mirrors the show-page load but resolves the `form` view kind (falling back
 * to no template when none exists — the page renders a fallback form).
 */
export const load: PageLoad = async ({ params, fetch }) => {
	const domain = params.domain;
	const doctypeLabel = decodeURIComponent(params.doctype);
	const docId = params.id;
	const qualifiedName = `${domain}.${doctypeLabel}`;
	const parentDocTypeId = qualifiedName;

	const driver = buildDriver(fetch);
	const { def, registry } = await resolveDoctype(domain, doctypeLabel, fetch);

	let doc: DocumentResponse<Record<string, unknown>>;
	try {
		doc = await driver
			.domain(domain)
			.doctype<Record<string, unknown>>(doctypeLabel)
			.doc(docId)
			.show();
	} catch (e) {
		rethrowLoadError(e, m.errors_document_load_failed());
	}

	const view: LoadedView = await loadDoctypeViewByKind(driver, parentDocTypeId, 'form');

	return {
		def,
		registry,
		qualifiedName,
		parentDocTypeId,
		docId,
		doc,
		view,
		driver
	};
};
