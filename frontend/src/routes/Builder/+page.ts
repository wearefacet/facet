// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { PageLoad } from './$types';
import { getPermissions } from '$lib/permissions.svelte';
import { DocumentDataDriver } from '$lib/datasource/DocumentDriver';
import { buildNavModel } from '$lib/navModel';
import { fetchDomainCheck, type DomainCheckResult } from '$lib/datasource/domainCheck.js';
import type { NavDomain } from '$lib/navTypes';

/** Each draft domain paired with its aggregated check result (or `undefined`
 *  when the fetch failed or hasn't resolved yet). The Builder landing renders
 *  issue-count chips per card from this. */
interface DraftWithCheck extends NavDomain {
	check: DomainCheckResult | undefined;
}

/**
 * Loads the draft-domain list and the live-domain list (for the
 * EditDomainDialog) for the Builder landing page. The drafts' aggregated
 * `/check` results are fetched in parallel so each draft card can render an
 * issue-count chip without a per-card round-trip on hover/click.
 */
export const load: PageLoad = async ({ fetch }) => {
	const driver = new DocumentDataDriver('', fetch);
	const perms = getPermissions() ?? undefined;

	const [drafts, live] = await Promise.all([
		buildNavModel(driver, perms, { drafts: true }),
		buildNavModel(driver, perms, { drafts: false })
	]);

	// Fetch each draft's /check result in parallel. Failures are swallowed —
	// the card still renders with `undefined` (the UI degrades to no chip).
	const draftsWithChecks: DraftWithCheck[] = await Promise.all(
		(drafts as NavDomain[]).map(async (d) => {
			let check: DomainCheckResult | undefined;
			try {
				check = await fetchDomainCheck(d.id, fetch);
			} catch {
				// 403 (no write perm) / 404 (deleted between list and check) / 500 —
				// the chip stays hidden; the user can still open the draft.
				check = undefined;
			}
			return { ...d, check };
		})
	);

	return { draftDomains: draftsWithChecks, liveDomains: live as NavDomain[] };
};
