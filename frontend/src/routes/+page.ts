// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { PageLoad } from './$types';
import { getPermissions } from '$lib/permissions.svelte';
import { DocumentDataDriver } from '$lib/datasource/DocumentDriver';
import { buildNavModel } from '$lib/navModel';
import { fetchDomainCheck, type DomainCheckResult } from '$lib/datasource/domainCheck.js';
import { apiFetch } from '$lib/session.svelte';

/**
 * The public summary of a launcher app, as returned by
 * `GET /Api/iam/apps`. Mirrors `IAM::AppLauncher::AppSummary` on the
 * backend — only the public, non-secret fields a launcher card needs.
 * `usable` is false when the active role does not meet the app's grant
 * requirements; the card then renders disabled with a notice.
 */
export type LauncherApp = {
	id: string;
	slug: string;
	display_name: string;
	description?: string;
	usable: boolean;
};

/**
 * Loads the draft domains (and their aggregated `/check` results) and the
 * launchable apps for the dashboard.
 *
 * Per-route (not in the layout) so it does not re-run on every navigation —
 * only when the user lands back on `/` (full load or `goto('/')`).
 *
 * The two fetches are independent and run in parallel. The apps fetch goes
 * through `apiFetch` (forwarding SvelteKit's `event.fetch`) so token
 * refresh and 401 recovery stay active during SSR.
 */
export const load: PageLoad = async ({ fetch }) => {
	const driver = new DocumentDataDriver('', fetch);
	const perms = getPermissions() ?? undefined;

	const [drafts, appsRes] = await Promise.all([
		buildNavModel(driver, perms, { drafts: true }),
		apiFetch('/Api/iam/apps', undefined, { fetch })
	]);

	const draftsWithChecks = await Promise.all(
		drafts.map(async (d) => {
			let check: DomainCheckResult | undefined;
			try {
				check = await fetchDomainCheck(d.id, fetch);
			} catch {
				check = undefined;
			}
			return { ...d, check };
		})
	);

	let apps: LauncherApp[] = [];
	if (appsRes.ok) {
		apps = (await appsRes.json()) as LauncherApp[];
	}

	return { draftDomains: draftsWithChecks, apps };
};
