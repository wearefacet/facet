// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { error } from '@sveltejs/kit';
import type { LayoutLoad } from './$types';
import { DocumentDataSource } from '$lib/datasource/DocumentDataSource';
import { loadDoctypeCatalogue } from '$lib/doctypeCatalogue';
import type { AppContent } from '$lib/app/appTypes';
import * as m from '$lib/paraglide/messages';

/**
 * App detail layout load. Mirrors the published-config detail pattern:
 *
 * 1. Resolve `slug → id` once via the `slug__eq` filter.
 * 2. Read the full document by `id`.
 * 3. Derive the active tab from the last URL segment so navigation is
 *    shareable. Tab switches do not refetch — the resolved `appId` and
 *    document are passed down via layout data so child pages read them
 *    from `{ data }`.
 *
 * A bare `/Configure/apps/[slug]` redirects to `overview` (the default
 * tab) — handled by the sibling `+page.ts`.
 */
const TABS = ['overview', 'grants', 'settings'] as const;
type Tab = (typeof TABS)[number];

export const load: LayoutLoad = async ({ params, url, fetch }) => {
	const slug = params.slug!;
	const seg = url.pathname.split('/').filter(Boolean).pop();
	const tab: Tab = TABS.includes(seg as Tab) ? (seg as Tab) : 'overview';

	const apps = new DocumentDataSource<AppContent>('app', 'App', undefined, fetch);

	// Slug→id resolution. The backend declares `operators: [eq, match]` on
	// `slug`; `slug__eq` is unique so the result is at most one row.
	let list;
	try {
		list = await apps.list({ filters: { slug__eq: slug } });
	} catch {
		throw error(502, m.configure_apps_registry_unreachable());
	}

	if (list.data.length === 0) {
		throw error(404, m.configure_apps_slug_not_found({ slug }));
	}

	const id = list.data[0].meta.id;
	const { data, meta } = await apps.doc(id).show();

	// The doctype catalogue is shared by the Grants tab and wizard step 3.
	// Loaded once here so tab switches do not refetch — it is the union of
	// every doctype the active role can read on `core.DocType`.
	const catalogue = await loadDoctypeCatalogue(fetch);

	return { slug, appId: id, app: { data, meta }, tab, catalogue: catalogue.entries };
};
