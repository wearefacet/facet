// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { LayoutLoad } from './$types';
import { error } from '@sveltejs/kit';
import { DocumentDataSource } from '$lib/datasource/DocumentDataSource';
import { loadDoctypeCatalogue } from '$lib/doctypeCatalogue';
import type { AppContent } from '$lib/app/appTypes';
import * as m from '$lib/paraglide/messages';

/**
 * Discovery document shape returned by
 * `/.well-known/oauth-authorization-server` (RFC 8414). Only the `issuer`
 * field is read — it is the Facet instance's public base URL, used by the
 * setup step to show the derived sign-in address live and by the credentials
 * screen to build the copy-pasteable client snippet.
 */
type OAuthDiscovery = { issuer?: string };

/**
 * Wizard layout load. The wizard's in-progress document id is threaded
 * through the `?app=<id>` query parameter (added with `replaceState`
 * after step 1's create). The setup step has no `app` param yet — it
 * creates the draft on Continue.
 *
 * For later steps, the layout reads the current document by id so the
 * stepper can show the live state and the step pages' `Continue` can
 * PATCH the same row. The doctype catalogue is loaded once here so the
 * permissions step does not refetch on entry.
 *
 * The OAuth issuer base is fetched once here from the discovery document
 * and threaded down so the setup and credentials screens share one source
 * of truth for the derived sign-in address.
 */
export const load: LayoutLoad = async ({ url, fetch, parent }) => {
	const appId = url.searchParams.get('app');
	// The bare /new entry (the "New app" button drives it) carries no step
	// segment — its last path piece is 'new' — and any unknown segment means
	// the same thing: no step chosen yet. Both resolve to 'setup', the step
	// the +page.ts redirect canonizes.
	const last = url.pathname.split('/').filter(Boolean).pop() ?? '';
	const step = (
		['setup', 'permissions', 'review', 'credentials'].includes(last) ? last : 'setup'
	) as 'setup' | 'permissions' | 'review' | 'credentials';

	if (!appId) {
		// Setup step has no draft yet. Other steps without an `app`
		// param are stale navigations (e.g. page refresh on step 2) —
		// bounce back to setup so the user starts a fresh draft.
		if (step !== 'setup') {
			throw error(400, m.configure_apps_no_draft_error());
		}
		// Even on the setup step we need the issuer base and the current
		// account (for the owner default), so those are still resolved below.
		const { issuerBase, currentAccount } = await loadShared(fetch, parent);
		return { step, app: null, catalogue: [], issuerBase, currentAccount };
	}

	const apps = new DocumentDataSource<AppContent>('app', 'App', undefined, fetch);
	let app;
	try {
		app = await apps.doc(appId).show();
	} catch {
		throw error(404, m.configure_apps_draft_missing_error());
	}

	const catalogue = await loadDoctypeCatalogue(fetch);
	const { issuerBase, currentAccount } = await loadShared(fetch, parent);
	return { step, app, catalogue: catalogue.entries, issuerBase, currentAccount };
};

/**
 * Loads the OAuth issuer base (from the discovery document) and the current
 * account (from the parent layout's server load, which forwards `locals.account`).
 *
 * The discovery fetch is tolerant: if the endpoint is unreachable or the
 * `issuer` field is absent, `issuerBase` falls back to the empty string and
 * the setup step hides the derived sign-in address panel rather than crashing.
 * The parent's `account` may be null when the visitor is unauthenticated, in
 * which case the setup step's owner field starts empty.
 */
async function loadShared(
	fetchFn: typeof fetch,
	parent: () => Promise<unknown>
): Promise<{ issuerBase: string; currentAccount: { id: string; displayName: string } | null }> {
	let issuerBase = '';
	try {
		const res = await fetchFn('/.well-known/oauth-authorization-server');
		if (res.ok) {
			const body = (await res.json()) as OAuthDiscovery;
			issuerBase = body.issuer ?? '';
		}
	} catch {
		// Network or parse error — fall back to empty so the UI degrades
		// gracefully (the sign-in address panel is hidden).
	}

	const parentData = (await parent()) as {
		account?: { id: string; display_name: string; email?: string } | null;
	};
	const u = parentData.account ?? null;
	const currentAccount = u
		? { id: u.id, displayName: u.display_name ?? u.email ?? 'Account' }
		: null;
	return { issuerBase, currentAccount };
}
