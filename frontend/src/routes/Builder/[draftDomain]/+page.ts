// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { redirect } from '@sveltejs/kit';
import type { PageLoad } from './$types';

/**
 * Redirects `/Builder/[draftDomain]` to the default `overview` tab so the
 * URL always reflects the active surface.
 */
export const load: PageLoad = async ({ params }) => {
	throw redirect(307, `/Builder/${params.draftDomain}/overview`);
};
