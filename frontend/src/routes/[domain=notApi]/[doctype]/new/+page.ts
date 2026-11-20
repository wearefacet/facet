// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { PageLoad } from './$types';
import { buildDriver, resolveDoctype } from '$lib/doctype/loadDoctypeDef.js';
import { loadDoctypeViewByKind, type LoadedView } from '$lib/doctype/loadDocumentView.js';

/**
 * Loads the doctype definition + `kind: form` view for the create route.
 *
 * Mirrors the edit page's load but does not fetch a document — the form is
 * seeded from field `default`s in the page component and a single `create`
 * is issued on save.
 */
export const load: PageLoad = async ({ params, fetch }) => {
	const domain = params.domain;
	const doctypeLabel = decodeURIComponent(params.doctype);
	const qualifiedName = `${domain}.${doctypeLabel}`;
	const parentDocTypeId = qualifiedName;

	const driver = buildDriver(fetch);
	const { def, registry } = await resolveDoctype(domain, doctypeLabel, fetch);
	const view: LoadedView = await loadDoctypeViewByKind(driver, parentDocTypeId, 'form');

	return {
		def,
		registry,
		qualifiedName,
		parentDocTypeId,
		view,
		driver
	};
};
