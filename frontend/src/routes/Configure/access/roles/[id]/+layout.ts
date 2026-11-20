// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { redirect } from '@sveltejs/kit';
import type { LayoutLoad } from './$types';

/**
 * Role detail layout load. The brief routes always include a tab
 * (`/roles/:id/details`, `/roles/:id/members`, or `/roles/:id/grants`).
 * A bare `/roles/:id` is ambiguous and has no content of its own; redirect
 * to `details` (the default tab) before rendering.
 */
export const load: LayoutLoad = ({ url, params }) => {
	const last = url.pathname.split('/').filter(Boolean).pop();
	if (last === params.id) {
		throw redirect(307, `/Configure/access/roles/${params.id}/details`);
	}
	return {};
};
