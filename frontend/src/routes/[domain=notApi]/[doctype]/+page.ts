// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { PageLoad } from './$types';
import { buildDriver, resolveDoctype } from '$lib/doctype/loadDoctypeDef.js';

/**
 * Loads the doctype definition for the requested `[domain]/[doctype]` route.
 *
 * The doctype label in the URL (e.g. "Company") is matched against the `doctype`
 * field of the `core.DocType` projection registry — those projections are
 * themselves the definition records. The registry is the 60s-TTL cached one
 * (see `clientCache.ts`), so a navigation here plus a sibling route load share
 * one `core.DocType?items=500` round-trip rather than each fetching twice.
 *
 * A `DoctypeRegistry` (driver + pre-fetched `doctypeDefinitions` map) is
 * returned so the `DoctypeEditor` can render in builder mode; the listing
 * `ListView` only needs the parsed `def`, the projection id (parent for the
 * `core.CollectionView` children), and the driver.
 */
export const load: PageLoad = async ({ params, fetch }) => {
	const domain = params.domain;
	const doctypeLabel = decodeURIComponent(params.doctype);
	const qualifiedName = `${domain}.${doctypeLabel}`;

	const driver = buildDriver(fetch);
	const { def, registry } = await resolveDoctype(domain, doctypeLabel, fetch);

	return {
		def,
		registry,
		qualifiedName,
		// Parent `core.DocType` projection id — the children endpoint base for
		// CollectionView CRUD. `core.DocType` projections use the qualified
		// doctype id as their row id.
		parentDocTypeId: qualifiedName,
		driver
	};
};
