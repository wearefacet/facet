// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { redirect } from '@sveltejs/kit';
import type { PageLoad } from './$types';

/**
 * Redirects `/Builder/[draftDomain]/[doctype]` to the default `fields` tab.
 */
export const load: PageLoad = async ({ params }) => {
	throw redirect(307, `/Builder/${params.draftDomain}/${params.doctype}/fields`);
};
