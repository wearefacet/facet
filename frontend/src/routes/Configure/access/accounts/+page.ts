// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { PageLoad } from './$types';
import { buildDriver, resolveDoctype } from '$lib/doctype/loadDoctypeDef.js';

/**
 * Loads the `iam.Account` doctype definition for the Configure accounts page.
 *
 * Accounts are an ordinary aggregate-root doctype, so the page renders the
 * standard `ListView` (tab-less) exactly like a live doctype listing. The
 * definition resolves through the 60s-TTL cached `DoctypeRegistry` — the same
 * snapshot the live `/iam/Account` routes share.
 */
export const load: PageLoad = async ({ fetch }) => {
	const driver = buildDriver(fetch);
	const { def } = await resolveDoctype('iam', 'Account', fetch);

	return {
		def,
		driver,
		// Qualified `core.DocType` projection id — the QuickView root parent id
		// (the same value the live doctype routes pass as `parentDocTypeId`).
		parentDocTypeId: 'iam.Account'
	};
};
