// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { PageLoad } from './$types';
import { buildDriver, resolveDoctype, rethrowLoadError } from '$lib/doctype/loadDoctypeDef.js';
import { loadDoctypeView, type LoadedView } from '$lib/doctype/loadDocumentView.js';
import { documentDependencyKey } from '$lib/documentSocket.svelte.js';
import type { DocumentResponse } from '$lib/datasource/types.js';
import * as m from '$lib/paraglide/messages';

/**
 * Loads a single document for the `/{domain}/{doctype}/{id}` show route.
 *
 * The doctype is resolved via the 60s-TTL cached `DoctypeRegistry` (shared
 * with the parent route and `loadDoctypeView`). The document and its view
 * template are then fetched normally.
 */
export const load: PageLoad = async ({ params, fetch, depends }) => {
	const domain = params.domain;
	const doctypeLabel = decodeURIComponent(params.doctype);
	const docId = params.id;
	const qualifiedName = `${domain}.${doctypeLabel}`;
	const parentDocTypeId = qualifiedName;

	// Declares this load as re-runnable for the live document channel: the
	// per-document WebSocket handler invalidates this key on any actor's
	// mutation, and only loads that depend on it re-run (the layout loads
	// carry no document data).
	depends(documentDependencyKey(docId));

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

	const view: LoadedView = await loadDoctypeView(driver, parentDocTypeId);

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
