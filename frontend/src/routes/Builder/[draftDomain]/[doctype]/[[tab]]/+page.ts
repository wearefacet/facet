// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { redirect } from '@sveltejs/kit';
import type { PageLoad } from './$types';

const VALID_TABS = ['general', 'fields', 'children', 'actions', 'logic', 'views'];
const DEFAULT_TAB = 'fields';

/**
 * Validates the optional `[[tab]]` param for the doctype editor. An empty or
 * unknown tab falls back to the default (`fields`) via a redirect, keeping the
 * URL canonical rather than surfacing a 404.
 */
export const load: PageLoad = async ({ params }) => {
	const tab = params.tab;
	if (tab === undefined || !VALID_TABS.includes(tab)) {
		throw redirect(307, `/Builder/${params.draftDomain}/${params.doctype}/${DEFAULT_TAB}`);
	}
};
