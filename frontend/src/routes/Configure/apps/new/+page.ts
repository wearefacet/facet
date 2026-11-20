// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { redirect } from '@sveltejs/kit';
import type { PageLoad } from './$types';

/**
 * The wizard shell owns no document of its own — each step page loads
 * the draft by id. A bare `/Configure/apps/new` redirects to the
 * first step so the entry URL is always canonical.
 */
export const load: PageLoad = () => {
	throw redirect(307, '/Configure/apps/new/setup');
};
