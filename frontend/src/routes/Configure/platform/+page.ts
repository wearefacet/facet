// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { redirect } from '@sveltejs/kit';
import { resolve } from '$app/paths';
import type { PageLoad } from './$types';

/**
 * The platform section owns no landing surface of its own — the real
 * screens are settings, indexes, artifacts and OIDC. A bare
 * `/Configure/platform` redirects to the settings page so the entry URL
 * is always canonical.
 */
export const load: PageLoad = () => {
	throw redirect(307, resolve('/Configure/platform/settings'));
};
