// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { redirect } from '@sveltejs/kit';
import type { LayoutLoad } from './$types';
import { can } from '$lib/permissions.svelte';

/**
 * Configure shell access gate.
 *
 * Any `/Configure/*` URL renders this shell. The workspace sidebar shows its
 * Configure entry only for a role that holds `update` on `core.DocType`
 * (see `NavPanel.svelte`). This gate applies the same check. The load
 * awaits `parent()`, so the root layout load fills the permission store
 * first. The check is therefore correct on the server and in the browser.
 * A role without the grant gets a redirect to `/` and never sees the shell.
 */
export const load: LayoutLoad = async ({ parent }) => {
	await parent();
	if (!can('core.DocType', 'update')) throw redirect(307, '/');
};
