// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { PageLoad } from './$types';
import { DocumentDataDriver } from '$lib/datasource/DocumentDriver';
import { DoctypeRegistry } from '$lib/datasource/DoctypeRegistry.js';
import { DataSourceError } from '$lib/datasource/types.js';
import type { NavDomain } from '$lib/navTypes';
import { domainProjectionToNavDomain, navDoctypesForDomain } from '$lib/navModel';
import { isPreviewActive } from '$lib/previewSession.svelte';
import { error } from '@sveltejs/kit';
import * as m from '$lib/paraglide/messages';

/**
 * Loads the domain dashboard at `/{domain}`.
 *
 * The active `NavDomain` is resolved from the parent layout's nav model
 * (`data.domains`) by id, so the dashboard reads the same color/label/doctype
 * set the sidebar renders. A SSR-safe driver is built for the per-doctype
 * `core.CollectionView` children fetches the dashboard issues.
 *
 * The `DoctypeRegistry` is the 60s-TTL cached snapshot shared with the nav
 * model and the doctype listing route, so a dashboard load plus a doctype
 * navigation share one `core.DocType?items=500` round-trip.
 *
 * **Preview carve-out:** when the URL targets a `_`-prefixed draft id and a
 * preview session is active, the parent's nav model may not yet have
 * re-built to include the draft (the root `+layout.ts` deliberately reads no
 * `url`/`params`, so client-side `goto('/_abc')` after `startPreview` does not
 * re-run the parent load on its own). In that case the bound draft is fetched
 * directly — `apiFetch` overlays the Bearer token, the backend's `PreviewEnforcer`
 * authorises the read, and the projection is converted to a `NavDomain` so the
 * dashboard renders against the draft's data on its own. The conversion leaves
 * the doctype list empty (a projection alone cannot provide one), so the list
 * is filled from the same cached registry snapshot the sidebar's nav model
 * reads (`navDoctypesForDomain`) — without a manifest filter, matching the
 * layout load's preview overlay.
 */
export const load: PageLoad = async ({ params, fetch, parent }) => {
	const parentData = await parent();
	const domains = (parentData.domains as NavDomain[] | undefined) ?? [];
	let domain = domains.find((d) => d.id === params.domain);

	// Built ahead of the preview carve-out so both paths share one registry
	// snapshot — on SSR `DoctypeRegistry.cached` does not cache, and the draft
	// path below needs the definitions to fill the draft's doctype list.
	const driver = new DocumentDataDriver('', fetch);
	const registry = await DoctypeRegistry.cached(driver);

	if (!domain && params.domain.startsWith('_') && isPreviewActive()) {
		// The root `+layout.ts` re-injects the preview session from the cookie
		// before this `load` runs on SSR, so `apiFetch` overlays the Bearer token
		// when the driver below issues the read.
		try {
			const proj = await driver.domain('core').doctype('Domain').doc(params.domain).show();
			domain = domainProjectionToNavDomain(proj);
			domain.doctypes = navDoctypesForDomain(registry, params.domain);
		} catch (err) {
			// Only a genuine backend 404 means "draft was never published / dropped".
			// 401 (dead preview token), 500, and network failures must propagate so
			// the real reason surfaces instead of being masked as a missing domain.
			if (err instanceof DataSourceError && err.status === 404) {
				throw error(404, m.errors_domain_not_found({ name: params.domain }));
			}
			throw err;
		}
	}

	if (!domain) {
		throw error(404, m.errors_domain_not_found({ name: params.domain }));
	}

	return { domain, registry, driver };
};
