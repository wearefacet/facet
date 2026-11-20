// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Post-login return URL.
 *
 * The redirect to `/Login` carries the page the visitor wanted as a
 * `redirectTo` query param. The URL is the only carrier: the server hook has
 * no access to browser storage. `routes/Login/+page.svelte` reads the param
 * after a successful sign-in and navigates to the target.
 *
 * Shared by `hooks.server.ts` (SSR loads) and `session.svelte.ts` (browser
 * `apiFetch`), so both sides send the same URL shape.
 */

/** Query-string key carrying the post-login return destination. */
export const REDIRECT_TO_PARAM = 'redirectTo';

/**
 * Builds the `/Login` redirect URL with the requested path + query embedded
 * as the `redirectTo` param.
 *
 * Only relative, same-origin paths are valid targets; anything that is not
 * `/`-prefixed, starts with `//`, or echoes back to `/Login` is dropped to
 * `/`. Without this guard a bad target could loop or send the user off-site
 * after login.
 */
export function buildLoginRedirect(path: string): string {
	let target = '/';
	if (path.startsWith('/') && !path.startsWith('//') && !path.startsWith('/Login')) {
		target = path;
	}
	return `/Login?${REDIRECT_TO_PARAM}=${encodeURIComponent(target)}`;
}
