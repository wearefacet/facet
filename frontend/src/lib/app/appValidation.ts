// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Pure validation and derivation helpers for the app wizard's setup and
 * credentials screens. None of these touch grants — they own the slug,
 * origin/redirect URI, sign-in address, and client snippet concerns.
 *
 * Pure (no Svelte, no state) so they can be unit-tested in the Vitest
 * `server` project.
 */

import type { AppContent, AppGrant } from './appTypes';
import { canonicalActions } from './appGrantsMapping';

/**
 * Convert a free-form display name into a URL-safe slug: lowercase, hyphens
 * for separators, `[a-z0-9-]` only, capped at 64 characters (the doctype's
 * `slug` field max). Consecutive separators are collapsed; leading/trailing
 * hyphens are stripped.
 *
 * Empty or all-non-alphanumeric input returns the empty string so the caller
 * can show a "required" state.
 */
export function toSlug(displayName: string): string {
	const cleaned = displayName
		.toLowerCase()
		.replace(/[^a-z0-9]+/g, '-')
		.replace(/^-+|-+$/g, '')
		.slice(0, 64);
	return cleaned;
}

/**
 * Returns `null` when `value` is a valid origin, or an error string otherwise.
 * A bare origin is scheme + host + optional port, with no path, query, or
 * fragment. `http:` and `https:` are both accepted (localhost dev uses http).
 */
export function validateOrigin(value: string): string | null {
	const trimmed = value.trim();
	if (!trimmed) return 'Required.';
	let u: URL;
	try {
		u = new URL(trimmed);
	} catch {
		return 'Not a valid URL.';
	}
	if (u.protocol !== 'http:' && u.protocol !== 'https:') {
		return 'Must be http(s).';
	}
	// A bare origin has an empty pathname (or just "/"), no query, no fragment.
	const barePath = u.pathname === '' || u.pathname === '/';
	if (!barePath || u.search !== '' || u.hash !== '') {
		return 'Use a bare origin (no path, query, or fragment).';
	}
	return null;
}

/**
 * Returns `null` when `value` is a valid redirect URI, or an error string
 * otherwise. A redirect URI is absolute, `https` (except `http://localhost`
 * for development), and has no fragment. The wildcard form `http://<loopback>:*`
 * (any port — RFC 8252, the OS assigns the local listener's port) is accepted
 * too; it mirrors the backend's `util.valid_redirect_uri` rule.
 */
const LOOPBACK_WILDCARD = /^http:\/\/(localhost|127\.0\.0\.1|\[::1\]):\*(\/.*)?$/i;

export function validateRedirectUri(value: string): string | null {
	const trimmed = value.trim();
	if (!trimmed) return 'Required.';
	if (LOOPBACK_WILDCARD.test(trimmed)) {
		return null;
	}
	let u: URL;
	try {
		u = new URL(trimmed);
	} catch {
		return 'Not a valid URL.';
	}
	const isLoopback =
		u.hostname === 'localhost' || u.hostname === '127.0.0.1' || u.hostname === '[::1]';
	if (u.protocol === 'http:' && !isLoopback) {
		return 'Must be https (http is only allowed for localhost).';
	}
	if (u.protocol !== 'https:' && !(u.protocol === 'http:' && isLoopback)) {
		return 'Must be http(s).';
	}
	if (u.hash !== '') {
		return 'No fragment allowed.';
	}
	if (trimmed.includes('*')) {
		return "The only permitted wildcard is a '*' port on an http loopback host.";
	}
	return null;
}

/**
 * Returns `true` when the origin of `redirectUri` is present in
 * `allowedOrigins`. Used by the setup screen to show the green "matches an
 * allowed origin" check under each redirect URI input.
 *
 * Both inputs are normalised by parsing through `URL` so trailing slashes,
 * default ports, and case differences on the host do not cause a false
 * negative. The loopback wildcard form has no single origin — it is never
 * "allowed" by this check.
 */
export function redirectOriginAllowed(redirectUri: string, allowedOrigins: string[]): boolean {
	if (LOOPBACK_WILDCARD.test(redirectUri.trim())) {
		return false;
	}
	let r: URL;
	try {
		r = new URL(redirectUri);
	} catch {
		return false;
	}
	const redirectOrigin = `${r.protocol}//${r.host}`;
	return allowedOrigins.some((o) => {
		try {
			const a = new URL(o);
			return `${a.protocol}//${a.host}` === redirectOrigin;
		} catch {
			return false;
		}
	});
}

/**
 * Derive the app's sign-in deep link: the shared OAuth authorization
 * endpoint that the discovery document advertises, addressed to this app's
 * client id. `issuerBase` is the Facet instance's public base URL (no
 * trailing slash); `clientId` is the app's immutable OAuth client id.
 *
 * There is no per-app sign-in route (B-200): OAuth identifies the app by
 * `client_id` at one shared endpoint — `GET /OAuth/authorize` requires the
 * `client_id` parameter — and discovery advertises the same
 * `${base}/OAuth/authorize` path (`src/oauth/discovery.cr`). Centralising
 * this in one pure function prevents the credentials screen and the client
 * snippet from drifting on the format.
 */
export function deriveSignInAddress(issuerBase: string, clientId: string): string {
	const base = issuerBase.replace(/\/+$/, '');
	return `${base}/OAuth/authorize?client_id=${encodeURIComponent(clientId)}`;
}

/**
 * Derive the OAuth discovery document URL suffix for an app. The full URL is
 * `${issuerBase}${discoveryPath()}`; the credentials screen shows this with a
 * copy button.
 *
 * The path follows RFC 8414 (OAuth 2.0 Authorization Server Metadata).
 */
export function discoveryPath(): string {
	return '/.well-known/oauth-authorization-server';
}

// ── Deployment serving (Part C) ─────────────────────────────────────────────────

/** Upper bound of the RFC 1034 hostname length. */
const HOST_MAX_LENGTH = 253;

/**
 * Shape rule for the app's `host` field — mirrors the backend's
 * `Util::ScriptHelpers::HOST_PATTERN` exactly: a bare lowercase hostname,
 * no scheme, no port, no path, no wildcard characters, dot-separated labels
 * of alphanumerics and inner hyphens, single labels (`localhost`) allowed.
 * The deployment target supplies the port at serve time.
 */
const HOST_PATTERN = /^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)*$/;

/**
 * Returns `null` when `value` is a valid app host, or an error string
 * otherwise. The wizard's "Facet serves this app" input and the deploy
 * panel both use this so the frontend never submits a host the backend's
 * Lua hook would reject.
 */
export function validateHostname(value: string): string | null {
	const trimmed = value.trim();
	if (!trimmed) return 'Required.';
	if (trimmed.length > HOST_MAX_LENGTH) return `Longer than ${HOST_MAX_LENGTH} characters.`;
	if (!HOST_PATTERN.test(trimmed)) {
		return 'Use a bare lowercase hostname — no scheme, port, path, or wildcards.';
	}
	return null;
}

/** Max length of a deployment file path (mirrors the deploy route). */
const DEPLOY_PATH_MAX_LENGTH = 1024;

/**
 * Returns `null` when `path` is a safe deployment file path, or an error
 * string otherwise. Mirrors the deploy route's safe-path rule: no leading
 * `/`, no `.` or `..` segments, no empty segments, bounded length. The
 * rule closes traversal and normalization bugs at the door.
 */
export function validateDeployPath(path: string): string | null {
	if (!path) return 'Empty path.';
	if (path.length > DEPLOY_PATH_MAX_LENGTH) {
		return `Longer than ${DEPLOY_PATH_MAX_LENGTH} characters.`;
	}
	if (path.startsWith('/')) return 'Must not start with `/`.';
	if (!path.split('/').every((segment) => segment !== '' && segment !== '.' && segment !== '..')) {
		return 'Must not contain empty, `.`, or `..` segments.';
	}
	return null;
}

// ── Client snippet ─────────────────────────────────────────────────────────────────

/**
 * Build the copy-pasteable curl example shown on the credentials screen for
 * a backend (`confidential`) app. The bearer key authenticates the app's
 * service identity, so a plain Document API call needs only the auth header.
 *
 * `$FACET_URL` is a placeholder for the instance's public base URL — the
 * developer substitutes their own host. The example lists a doctype
 * collection because that is the simplest read the key can make.
 */
export function buildCurlSnippet(key: string): string {
	return [
		"# List contacts as the app's service identity",
		'curl "$FACET_URL/Api/crm/Contact" \\',
		`  -H "Authorization: Bearer ${key}"`
	].join('\n');
}

/**
 * Build the copy-pasteable TypeScript snippet shown on the credentials
 * success screen. The snippet assumes a `createClient` helper whose shape
 * mirrors the future Facet client library; the scope strings follow the
 * `${domain}.${doctype}:${action}` convention.
 *
 * If the app has no grants yet, the `scopes` array is empty so the snippet
 * still pastes and runs without raising.
 *
 * The scope-string conversion is a **frontend convention for the snippet
 * only**; it does not change the backend grant shape or the token's actual
 * scope serialisation.
 */
export function buildClientSnippet(app: AppContent, issuerBase: string): string {
	const clientId = app.client_id ?? '';
	const redirectUri = Array.isArray(app.redirect_uris) ? (app.redirect_uris[0] ?? '') : '';
	const signIn = deriveSignInAddress(issuerBase, clientId);
	const scopes = grantsToScopes(app.grants ?? []);

	const lines: string[] = ['// facet-client.ts', 'const facet = createClient({'];
	lines.push(`  issuer: ${quote(issuerBase)},`);
	lines.push(`  clientId: ${quote(clientId)},`);
	if (redirectUri) lines.push(`  redirectUri: ${quote(redirectUri)},`);
	lines.push(`  authorizationEndpoint: ${quote(signIn)},`);
	lines.push(`  scopes: [${scopes.map((s) => quote(s)).join(', ')}]`);
	lines.push('})');
	return lines.join('\n');
}

/**
 * Convert the stored grants array into the flat scope-string list the
 * snippet uses: `{target: 'crm.Company', actions: [{name: 'write'...}]}` →
 * `crm.company:create`, `crm.company:update`.
 *
 * - The target's domain is lowercased; the doctype name is lowercased.
 * - Action names are canonicalised first (see `canonicalActions`): the
 *   `write` alias expands to its `create`/`update` pair, so the snippet
 *   names the actions the runtime enforcer actually checks. The server does
 *   not parse the requested `scope` — this list is documentation for the
 *   client developer.
 * - Wildcard domain grants (`crm.*`) render as `crm.*` for every action.
 *
 * The result is de-duplicated and stably ordered (by target, then action
 * name) so the snippet does not reshuffle across renders.
 */
export function grantsToScopes(grants: AppGrant[]): string[] {
	const arr = Array.isArray(grants) ? (grants as AppGrant[]) : ([] as AppGrant[]);
	const scopes = new Set<string>();
	for (const grant of arr) {
		const dot = grant.target.lastIndexOf('.');
		if (dot === -1) continue;
		const domain = grant.target.slice(0, dot).toLowerCase();
		const doctype = grant.target.slice(dot + 1).toLowerCase();
		const qualifiedDoctype = `${domain}.${doctype}`;
		for (const action of canonicalActions(grant.actions ?? [])) {
			scopes.add(`${qualifiedDoctype}:${action.name}`);
		}
	}
	return [...scopes].sort();
}

function quote(s: string): string {
	return `"${s.replace(/"/g, '\\"')}"`;
}
