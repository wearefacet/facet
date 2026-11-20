// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { redirect } from '@sveltejs/kit';
import type { PageLoad } from './$types';

/**
 * Bare `/Configure/domains/[slug]` has no own surface — redirect to the
 * canonical `overview` tab. Mirrors the app-detail pattern. The target
 * must be absolute (not `./overview`): a relative redirect resolves
 * against the request path and would drop the `[slug]` segment.
 */
export const prerender = false;
export const load: PageLoad = ({ params }) => {
	throw redirect(307, `/Configure/domains/${params.slug}/overview`);
};
