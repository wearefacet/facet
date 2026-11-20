// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { page } from '$app/state';
import { goto } from '$app/navigation';

/**
 * Patch the current URL's query parameters without a history entry — the
 * shared idiom for URL-backed UI state (selected view, trash mode, tab
 * selection). `null` / `undefined` values delete the key; empty strings are
 * kept (an empty value can be meaningful).
 *
 * This runs a real client-side navigation with `replaceState`, not a bare
 * `history.replaceState`: SvelteKit keeps `page.url` pinned to the rendered
 * page across `history.replaceState` (and its `replaceState` wrapper — both
 * update `page.state` only), so components deriving state from
 * `page.url.searchParams` would never see a shallow write. Through `goto`,
 * `page.url` updates reactively, and load functions that read the touched
 * params re-run per SvelteKit's dependency tracking (the loads on the surfaces
 * that use this helper read no query params, so the toggle stays cheap — one
 * `__data.json` round trip, no load re-runs).
 */
export function setSearchParams(patch: Record<string, string | null | undefined>): void {
	const url = new URL(page.url);
	for (const [key, value] of Object.entries(patch)) {
		if (value === null || value === undefined) {
			url.searchParams.delete(key);
		} else {
			url.searchParams.set(key, value);
		}
	}
	if (url.href === page.url.href) return;
	// The target is the CURRENT page with a patched query — no single route id
	// exists in a generic helper; the caller's route owns the id.
	// eslint-disable-next-line svelte/no-navigation-without-resolve -- current-page rewrite, see above
	void goto(url, { replaceState: true, noScroll: true, keepFocus: true });
}
