// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { error } from '@sveltejs/kit';
import type { LayoutLoad } from './$types';
import * as m from '$lib/paraglide/messages';
import { DocumentDataDriver } from '$lib/datasource/DocumentDriver';
import { DoctypeRegistry } from '$lib/datasource/DoctypeRegistry.js';
import { doctypeRegistryCache } from '$lib/datasource/clientCache.js';
import { parseDoctypeDef, type DoctypeDef } from '$lib/doctype/types.js';
import { loadDoctypeViewsWithIds } from '$lib/doctype/loadDocumentView.js';
import type { ViewKind } from '$lib/doctype/previewDocument.js';
import type { TemplateNode } from '$lib/template-types.js';

/**
 * Loads the doctype definition for the `[draftDomain]/[doctype]` Builder route.
 * Matches the doctype label against `core.DocType` projections in the draft
 * domain, then parses into a `DoctypeDef` for the `DoctypeEditor`.
 *
 * Uses the cached `DoctypeRegistry` so it shares one `core.DocType` round-trip
 * with the parent route load, the nav rebuild, etc.
 */
export const load: LayoutLoad = async ({ params, fetch }) => {
	const domain = params.draftDomain;
	const doctypeLabel = decodeURIComponent(params.doctype);
	const qualifiedName = `${domain}.${doctypeLabel}`;

	const driver = new DocumentDataDriver('', fetch);
	let registry = await DoctypeRegistry.cached(driver);
	let match = registry.doctypeDefinitions.get(qualifiedName);

	if (!match) {
		// 60s TTL can lag a freshly-created doctype — invalidate and refetch once.
		doctypeRegistryCache.invalidate();
		registry = await DoctypeRegistry.from(driver);
		match = registry.doctypeDefinitions.get(qualifiedName);
	}

	if (!match) {
		throw error(404, m.errors_doctype_not_found({ name: qualifiedName }));
	}

	const def = parseDoctypeDef(match as Record<string, unknown>);
	// Templates feed the preview; the child ids let the Views tab PATCH a
	// stored view instead of creating a duplicate of the same kind. Fresh
	// fetch: a route entry or an `invalidateAll()` re-run must not serve a
	// cached list older than an external write (a second tab, an assistant).
	const { templates: views, ids: viewIds } = await loadDoctypeViewsWithIds(driver, qualifiedName, {
		fresh: true
	});
	return {
		def: def as DoctypeDef,
		registry,
		qualifiedName,
		views: views as Partial<Record<ViewKind, TemplateNode | null>>,
		viewIds
	};
};
