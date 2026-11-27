// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { sequence } from '@sveltejs/kit/hooks';
import { redirect, isHttpError, type Handle, type HandleFetch } from '@sveltejs/kit';
import { env as privateEnv } from '$env/dynamic/private';
import { getTextDirection } from '$lib/paraglide/runtime';
import { paraglideMiddleware } from '$lib/paraglide/server';
import * as m from '$lib/paraglide/messages';
import { apiFetch } from '$lib/session.svelte';
import { applySetCookies } from '$lib/ssrCookies';
import { CSP_NONCE_PLACEHOLDER, contentSecurityPolicy, mintNonce } from '$lib/csp';
import { buildLoginRedirect } from '$lib/loginRedirect';
import { DataSourceError } from '$lib/datasource/types';
import type { PermissionManifest, ScopeManifest } from '$lib/navModel';

/** Cookie mirroring the in-memory `previewSession.svelte` store for F5-survival. */
const PREVIEW_COOKIE_KEY = 'facet.preview-session';

const handleFetch: HandleFetch = async ({ event, request, fetch }) => {
	// Caddy forwards the backend namespaces to the backend, but a server-side
	// load's event.fetch never reaches Caddy: SvelteKit re-enters its own
	// pipeline for same-origin paths and answers its own 404 for non-route
	// paths. When BACKEND_URL is configured, rewrite the backend namespaces
	// (/Api/* REST + MCP, /OAuth/* authorization) straight to the backend and
	// forward the session cookie manually, because SvelteKit's subdomain cookie
	// passthrough does not apply across the (possibly different) host.
	const backend = privateEnv.BACKEND_URL;
	const rewritten = backend ? await rewriteToBackend(event, request, backend) : request;

	const response = await fetch(rewritten);

	// The rewrite makes the URL cross-origin, and SvelteKit propagates
	// Set-Cookie back to the browser only for same-origin event.fetch — backend
	// cookies would be dropped. Re-issue them through event.cookies so they
	// reach the browser (token rotation during SSR, e.g. POST /Api/iam/refresh,
	// depends on this). See `ssrCookies.ts` for the full rationale.
	if (rewritten !== request) {
		applySetCookies(event, response);
	}

	return response;
};

/**
 * Rewrites `/Api/*` and `/OAuth/*` fetches to the plain-HTTP backend and
 * returns the new Request. Returns the input unchanged for every other path,
 * and when no backend address is configured (the reverse proxy owns those
 * paths).
 */
async function rewriteToBackend(
	event: Parameters<HandleFetch>[0]['event'],
	request: Request,
	backendUrl: string
): Promise<Request> {
	const url = new URL(request.url);
	if (!url.pathname.startsWith('/Api/') && !url.pathname.startsWith('/OAuth/')) {
		return request;
	}

	const backend = new URL(backendUrl || 'http://127.0.0.1:3000');
	url.protocol = backend.protocol;
	url.hostname = backend.hostname;
	url.port = backend.port;

	const headers = new Headers(request.headers);
	const cookie = forwardedCookieHeader(event, request.headers.get('cookie'));
	if (cookie) headers.set('cookie', cookie);

	// The body must be buffered before building the new Request: passing the
	// original Request's stream body straight through throws in Node
	// ("RequestInit: duplex option is required when sending a body"), which
	// silently killed every POST through this rewrite — including the SSR
	// token refresh, the disconnect this hook's refresh flow is meant to
	// prevent. arrayBuffer() works for the JSON bodies every SSR call sends.
	const body =
		request.method === 'GET' || request.method === 'HEAD' ? undefined : await request.arrayBuffer();

	return new Request(url, {
		method: request.method,
		headers,
		redirect: request.redirect,
		referrer: request.referrer,
		mode: request.mode,
		credentials: request.credentials,
		body
	});
}

/**
 * Builds the cookie header forwarded to the backend from the event's live
 * cookie jar instead of the page-load request's raw header. An earlier
 * same-event fetch can set cookies (e.g. `handleAuth` completing an SSR token
 * refresh before the layout loads run); those must reach the backend too,
 * otherwise the stale original header triggers a second refresh per request.
 * Values are already decoded by SvelteKit; the backend cookie values (JWT,
 * `session_id.refresh_id`) contain no characters the round-trip could alter.
 */
function forwardedCookieHeader(
	event: Parameters<HandleFetch>[0]['event'],
	fallback: string | null
): string | null {
	const merged = event.cookies
		.getAll()
		.map((c) => `${c.name}=${c.value}`)
		.join('; ');
	return merged || fallback;
}

const handleParaglide: Handle = ({ event, resolve }) =>
	paraglideMiddleware(event.request, ({ request, locale }) => {
		event.request = request;

		return resolve(event, {
			transformPageChunk: ({ html }) =>
				html
					.replace('%paraglide.lang%', locale)
					.replace('%paraglide.dir%', getTextDirection(locale))
		});
	});

/**
 * Sends the Content-Security-Policy and renders the per-request nonce into
 * every inline script. SvelteKit emits one inline script (its start shim)
 * and `src/app.html` carries the pre-paint theme script; both need the
 * nonce, and SvelteKit's own `csp` option cannot supply one alongside a
 * `script-src` directive. See `$lib/csp.ts` for why the policy lives here.
 * The page chunk is streamed, so an inline tag may straddle two chunks;
 * `carry` holds the unfinished tail until the next chunk. A response with
 * no page chunk (a JSON API reply, a redirect, an asset) is untouched.
 */
const handleCsp: Handle = async ({ event, resolve }) => {
	const nonce = mintNonce();
	let carry = '';
	let transformed = false;

	// The theme script carries the `%facet.nonce%` placeholder; SvelteKit's
	// own start shim is emitted at render time with no attributes — a bare
	// `<script>` tag. Both are inline and need the nonce; `src` scripts must
	// not be touched. The shim tag is shorter than the carry tail, so a tag
	// split across two chunks is still stamped.
	const stamp = (html: string): string =>
		html.split(CSP_NONCE_PLACEHOLDER).join(nonce).split('<script>').join(`<script nonce="${nonce}">`);

	const response = await resolve(event, {
		transformPageChunk: ({ html, done }: { html: string; done: boolean }) => {
			transformed = true;
			const chunk = carry + html;
			if (!done) {
				const keep = Math.min(CSP_NONCE_PLACEHOLDER.length - 1, chunk.length);
				carry = chunk.slice(chunk.length - keep);
				return stamp(chunk.slice(0, chunk.length - keep));
			}
			carry = '';
			return stamp(chunk);
		}
	});

	if (transformed) {
		response.headers.set('Content-Security-Policy', contentSecurityPolicy(nonce));
	}
	return response;
};

interface MeResponse {
	account: { id: string; display_name: string; email?: string };
	active_role: string;
	available_roles: string[];
	expires_at: number;
	permissions?: PermissionManifest;
	scopes?: ScopeManifest;
	/** The active role's `visible_tags` — the field-tag visibility set the
	 * backend read mask applies (B-176). Absent on older payloads or when
	 * the role projection is missing; the store then applies no filter. */
	visible_tags?: string[];
	/** Workspace-assistant availability of the request's ACTIVE role
	 * (`Assistant::Access` — exactly one role is active per request);
	 * `token_budget` stays the MAX over the account's held roles. `configured`
	 * reports whether an API key resolves installation-wide (sealed settings
	 * slot, then the file's `!env?` value) — `false` keeps the dock visible
	 * but disables conversation creation. Absent on older payloads — treated
	 * as off / unconfigured. */
	assistant?: { access: boolean; configured?: boolean; token_budget: number | null; name?: string };
	/** The active role's connectivity channels (closed vocabulary: mcp,
	 * webhook, api, assistant). Absent on older payloads — treated as an
	 * empty list (browser-only); the backend gates the channels themselves. */
	connectivity?: string[];
}

/**
 * Session guard. Runs on every server request (full loads / SSR). Performs
 * the `/Api/iam/me` check and login redirect here so the root layout `load`
 * can stay free of `url` dependencies — preventing it from re-running on
 * client-side navigations (which was the source of the tab-switch flicker).
 *
 * The result is attached to `event.locals`; the root `+layout.server.ts`
 * forwards it to the universal `+layout.ts`, which hydrates the client-side
 * permission/expiry stores and builds the nav model. Client-side navigations
 * no longer re-fetch the session: token refresh + 401 recovery still happen
 * transparently inside `apiFetch` for individual API calls.
 */
const handleAuth: Handle = async ({ event, resolve }) => {
	// `/login` is a case variant of the sign-in route. SvelteKit route
	// matching is case-sensitive, so `/login` matches no static route. The
	// domain matcher (`params/notApi.ts`) accepts it, and the request lands
	// on the domain dashboard for a domain named "login". A signed-in
	// visitor then gets a 404. Redirect to the canonical `/Login` before the
	// domain-matcher routing runs. The query string stays.
	if (event.url.pathname === '/login') {
		redirect(303, `/Login${event.url.search}`);
	}

	// SvelteKit's `event.fetch` for same-origin URLs re-enters the full request
	// pipeline (`respond` → hooks), so calling `event.fetch('/Api/...')` inside
	// this hook would recurse infinitely. Skip `/Api/` paths — they are proxied
	// to the backend (via the Caddy dev proxy, or the reverse proxy in
	// production), and the backend enforces its own auth via cookies.
	if (event.url.pathname.startsWith('/Api/')) {
		return resolve(event);
	}

	// Public auth surfaces: `/Login` and `/ResetPassword` (the emailed
	// reset / invite-acceptance link lands here with no session). Both skip
	// the unauthenticated login redirect; a valid token is the authorization
	// on the reset route, so an already-authenticated visitor may also use it.
	const isLoginRoute = event.route.id === '/Login';
	const isPublicAuthRoute = isLoginRoute || event.route.id === '/ResetPassword';

	const res = await apiFetch(
		'/Api/iam/me',
		{},
		{ fetch: event.fetch, redirectOnFailure: false, attemptRefresh: !isPublicAuthRoute }
	);

	if (res.status === 401) {
		event.locals = {
			account: null,
			activeRole: null,
			availableRoles: null,
			authenticated: false,
			permissions: null,
			scopes: null,
			visibleTags: null,
			expiresAt: null,
			assistantAccess: false,
			assistantConfigured: false,
			assistantName: null,
			connectivity: null,
			previewSession: null
		};
		if (!isPublicAuthRoute) {
			// Embed the requested path + query in the login URL so the login page
			// can return the user there after a successful sign-in. The target is
			// carried via the URL (not client storage) because this hook runs on
			// the server, where there is no shared browser `sessionStorage`.
			throw redirect(303, buildLoginRedirect(event.url.pathname + event.url.search));
		}
	} else if (!res.ok) {
		throw new Error(m.errors_session_load({ status: res.status }));
	} else {
		const data: MeResponse = await res.json();
		if (isLoginRoute) throw redirect(303, '/');
		event.locals = {
			account: { id: data.account.id, display_name: data.account.display_name ?? 'Administrator' },
			activeRole: data.active_role,
			availableRoles: data.available_roles,
			authenticated: true,
			permissions: data.permissions ?? null,
			scopes: data.scopes ?? null,
			visibleTags: data.visible_tags ?? null,
			expiresAt: data.expires_at,
			// Fail closed when the payload carries no assistant section.
			assistantAccess: data.assistant?.access === true,
			// Whether the installation has an AI provider at all (an API key
			// resolves). Fail closed when the payload predates the key.
			assistantConfigured: data.assistant?.configured === true,
			// The one display name every assistant surface shows (window
			// headers, turn headers, top-bar pill). The backend always resolves
			// it — the file tier carries the "Assistant" default.
			assistantName: data.assistant?.name ?? null,
			// Fail closed when the payload carries no connectivity list.
			connectivity: data.connectivity ?? [],
			previewSession: readPreviewCookie(event)
		};
	}

	// A 401 that escapes a load means the session died after the
	// `/Api/iam/me` check but before the load's own API call, and the token
	// refresh failed too. On SSR `apiFetch` cannot redirect (no `window`),
	// so the failure surfaces here as a `DataSourceError` (raw, or wrapped
	// by `rethrowLoadError`). Recover instead of rendering the error page.
	try {
		return await resolve(event);
	} catch (err) {
		if (
			(err instanceof DataSourceError && err.status === 401) ||
			(isHttpError(err) && err.status === 401)
		) {
			const preview = event.locals.previewSession;
			if (preview) {
				// The preview capability token died (TTL elapsed, draft published
				// or dropped); the cookie session is still valid, so `/Login` is
				// the wrong target — and it would loop: this server cannot clear
				// the browser's `facet.preview-session` cookie from inside
				// `apiFetch`, so every request would re-inject the dead token and
				// 401 again. Delete the cookie on this redirect response
				// (SvelteKit applies `event.cookies` mutations to hook-thrown
				// redirects) and land in the draft's editor, where the user can
				// re-enter preview.
				event.cookies.delete(PREVIEW_COOKIE_KEY, { path: '/' });
				redirect(303, `/Builder/${preview.draftId}`);
			}
			// Same shape as the me-check redirect above: the login page returns
			// the user to the requested path after a successful sign-in.
			redirect(303, buildLoginRedirect(event.url.pathname + event.url.search));
		}
		throw err;
	}
};

export const handle = sequence(handleCsp, handleAuth, handleParaglide);

export { handleFetch };

/**
 * Reads the `facet.preview-session` cookie (mirrored by `previewSession.svelte`'s
 * `setPreviewSession`) and returns its payload when present and unexpired.
 * Returns `null` when no cookie is set or the payload is malformed/expired —
 * SSR then runs without a preview overlay and the request is authorised by
 * the regular cookie session.
 *
 * The cookie carries the same payload as `sessionStorage` because the token
 * must reach the server-side `apiFetch` overlay during a full reload of a
 * live URL. The cookie is NOT HttpOnly (JavaScript writes/clears it in
 * tandem with the in-memory store), so it is intentionally not the auth
 * source of truth — the bearer header injected by `apiFetch` is.
 */
function readPreviewCookie(event: Parameters<Handle>[0]['event']): App.PreviewSessionCookie | null {
	const raw = event.cookies.get(PREVIEW_COOKIE_KEY);
	if (!raw) return null;
	try {
		const parsed = JSON.parse(decodeURIComponent(raw)) as App.PreviewSessionCookie;
		if (parsed.expiresAt > Math.floor(Date.now() / 1000)) {
			return parsed;
		}
	} catch {
		/* malformed cookie — ignore; in-memory store will rewrite it on next set */
	}
	return null;
}
