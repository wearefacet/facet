// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Content-Security-Policy nonce plumbing for the document headers.
 *
 * SvelteKit always emits one inline script — its own start shim that
 * defines `__sveltekit_*` and calls `start()` — and the app template adds
 * the pre-paint theme script. A `script-src 'self'` policy without a nonce
 * blocks both, so the page renders and never boots (the production edge
 * sent exactly that header: the login form was inert).
 *
 * SvelteKit's `csp` option does not cover this: `directives` with
 * `script-src` disables its nonce (a directive set counts as user-supplied
 * CSP), and `enableInlineScripts: false` would leave the start shim out and
 * break hydration. So the policy is owned here: `hooks.server.ts` mints a
 * per-request nonce, renders it into every inline `<script>`, and sends the
 * header; `docker/Caddyfile.prod` sends no CSP for the frontend vhost.
 *
 * The policy is a single source of truth because the header and the markup
 * must agree on the nonce, and the Caddyfile must not restate the rules.
 */

export const CSP_NONCE_PLACEHOLDER = '%facet.nonce%';

/**
 * The response header value. `script-src` allows the request's nonce and
 * no inline script otherwise; `style-src` keeps `'unsafe-inline'` because
 * the UI sets inline styles. `connect-src` allows `wss:` for the live
 * event socket; `frame-ancestors` and `base-uri` are pinned to `'self'`.
 */
export function contentSecurityPolicy(nonce: string): string {
	return [
		"default-src 'self'",
		`script-src 'self' 'nonce-${nonce}'`,
		"style-src 'self' 'unsafe-inline'",
		"img-src 'self' data: blob:",
		"font-src 'self' data:",
		"connect-src 'self' wss:",
		"object-src 'none'",
		"base-uri 'self'",
		"form-action 'self'",
		"frame-ancestors 'self'"
	].join('; ');
}

/** A fresh 128-bit nonce, base64 (the CSP nonce alphabet). */
export function mintNonce(): string {
	const bytes = new Uint8Array(16);
	crypto.getRandomValues(bytes);
	return btoa(String.fromCharCode(...bytes));
}
