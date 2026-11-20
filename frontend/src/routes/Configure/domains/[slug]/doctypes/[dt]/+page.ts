// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { PageLoad } from './$types';

/**
 * Per-doctype published detail load. Surfaces the slug and doctype from
 * route params onto `data` so the page component can read them reactively
 * without poking `page.params` directly (which would not re-run when the
 * URL changes within the same component instance).
 */
export const load: PageLoad = ({ params }) => {
	return { slug: params.slug!, dt: params.dt! };
};
