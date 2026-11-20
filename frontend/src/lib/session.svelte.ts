// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Session state + `apiFetch` — auto-refreshing token management.
 *
 * The access token lives in an HttpOnly cookie (JavaScript cannot read it).
 * The backend returns `expires_at` (Unix timestamp, seconds) in every
 * login, refresh, and `/Api/iam/me` response. This module tracks that
 * timestamp and wraps `fetch` so that:
 *
 * 1. **Pre-emptive refresh**: if the token expires within 60s, `apiFetch`
 *    calls `/Api/iam/refresh` before making the actual request.
 * 2. **Reactive 401 recovery**: if a 401 is received (token already expired
 *    on the server), `apiFetch` tries one refresh, then retries the original
 *    request. If the refresh itself fails, the caller decides what to do:
 *    browser XHR callers are redirected to `/Login?redirectTo=<path+query>`
 *    by default (see `loginRedirect.ts`); the universal layout load passes
 *    `redirectOnFailure: false` and handles the redirect itself via
 *    SvelteKit's `throw redirect` (so it stays SSR-safe and respects the
 *    login-route exception). On SSR there is no `window`, so the 401
 *    `Response` is returned and `hooks.server.ts` turns a load failure into
 *    the same redirect.
 *
 * Both behaviours are gated on `opts.attemptRefresh` (default `true`). Auth
 * endpoints where a 401 is an expected outcome — not a session-expiry signal —
 * opt out: `/Api/iam/login` returns 401 for bad credentials, and `/Api/iam/me`
 * on the `/Login` route returns 401 for a not-yet-authenticated visitor.
 * Treating those as recoverable would trigger a pointless refresh and, for
 * browser callers, a reload loop back to `/Login`.
 *
 * Refresh tokens are also HttpOnly cookies — JavaScript never touches token
 * values directly.
 *
 * When a refresh response lands, a `facet:permissions-update` signal is
 * dispatched (browser only) so the root layout and Configure pages re-run
 * `invalidateAll()`, which re-hydrates the permissions *and* scopes stores
 * from a fresh `/Api/iam/me`. The event carries no payload: it is a pure
 * signal. During SSR the event is suppressed — the universal load applies
 * permissions directly from the `/Api/iam/me` response body instead.
 * Sending only `permissions` in the payload (the prior behaviour) left the
 * `scopes` store stale after a role switch or a background refresh.
 *
 * ## SSR safety
 *
 * `apiFetch` and `tryRefresh` accept an optional `fetch` function. The
 * universal `+layout.ts` load passes SvelteKit's `event.fetch` so cookies
 * (both `auth_token` and `refresh_token`) are forwarded on same-origin SSR
 * requests and `Set-Cookie` responses propagate back to the browser. All
 * `window` access is guarded so these functions are safe to call on the
 * server.
 *
 * Module-level state (`expiresAt`, `refreshing`) is gated on the browser:
 * `setExpiresAt` is a no-op on the server and `tryRefresh` never populates
 * `refreshing` there. This prevents one user's session-expiry timestamp or
 * in-flight refresh promise from leaking into another user's SSR request.
 * The trade-off is that pre-emptive refresh is a client-only optimisation on
 * SSR — the 401-recovery path (which does not depend on `expiresAt` and uses
 * the request's own `fetchFn` cookies) is the server-side fallback.
 */

import { getPreviewSession, clearPreviewSession } from './previewSession.svelte.js';
import { PERMISSIONS_UPDATE_EVENT } from '$lib/authorization/permissionRefresh.svelte.js';
import { buildLoginRedirect } from './loginRedirect.js';

const REFRESH_THRESHOLD = 60; // seconds before expiry to trigger pre-emptive refresh

// Module-level state — only meaningful in the browser, where a single tab has
// one session. On the server this would be shared across concurrent users, so
// all reads and writes below guard on `typeof window === 'undefined'` and
// no-op on SSR. The 401-recovery path is unaffected: it does not depend on
// `expiresAt` and uses the request's own `fetchFn` cookies for the refresh.
let expiresAt: number | null = null;

export function setExpiresAt(ts: number | null): void {
	// Only track on the client; module-level state on the server would leak
	// across users.
	if (typeof window === 'undefined') return;
	expiresAt = ts;
}

export function getExpiresAt(): number | null {
	// On the server the value is meaningless; report null so `apiFetch`'s
	// pre-emptive branch is skipped and 401 recovery takes over when needed.
	if (typeof window === 'undefined') return null;
	return expiresAt;
}

let refreshing: Promise<boolean> | null = null;

/**
 * Attempts a token refresh via `/Api/iam/refresh`.
 *
 * Deduplicates concurrent calls on the client (all waiters share the same
 * refresh promise). On the server, dedup is skipped so concurrent SSR
 * requests for different users do not share a refresh promise. Module-level
 * `refreshing` is never populated on the server, so it cannot leak across
 * requests.
 *
 * Returns `true` on success, `false` on failure.
 */
async function tryRefresh(fetchFn: typeof fetch = fetch): Promise<boolean> {
	const isBrowser = typeof window !== 'undefined';

	// Dedup only on the client — module-level state would be shared across
	// users on the server.
	if (isBrowser && refreshing) return refreshing;

	const promise = (async () => {
		try {
			const res = await fetchFn('/Api/iam/refresh', {
				method: 'POST',
				headers: {
					'Content-Type': 'application/json',
					'X-Requested-With': 'XMLHttpRequest'
				},
				body: JSON.stringify({ cookie: true }),
				credentials: 'include'
			});

			if (!res.ok) return false;

			const body = await res.json();
			// Only track the new expiry on the client. On the server this is
			// shared module-level state; the caller's request-scoped value is in
			// the response body and read by the universal layout load instead.
			if (body.expires_at && isBrowser) {
				expiresAt = body.expires_at;
			}
			if (isBrowser) {
				// Signal-only: the layout's handler and the Configure pages re-run
				// `invalidateAll()` on this event, which re-derives permissions AND
				// scopes from a fresh `/Api/iam/me`. Previously this dispatched
				// `detail: body.permissions` only, which left the `scopes` store
				// pointing at the previous role's scopes — a silent half-update.
				window.dispatchEvent(new CustomEvent(PERMISSIONS_UPDATE_EVENT));
			}
			return true;
		} catch {
			return false;
		}
	})();

	if (isBrowser) {
		refreshing = promise;
		// Clear only if we are still the active refresh, so a later call's
		// promise is not clobbered by an older one settling.
		promise.finally(() => {
			if (refreshing === promise) refreshing = null;
		});
	}

	return promise;
}

/**
 * Smart `fetch` wrapper that auto-refreshes the access token before it expires.
 *
 * Use this instead of the native `fetch` for all API calls that require
 * authentication. It sends `credentials: 'include'` so HttpOnly cookies are
 * forwarded automatically, and handles token refresh transparently.
 *
 * Mutating calls (POST / PATCH / PUT / DELETE) also carry an
 * `X-Requested-With: XMLHttpRequest` header unless the caller set one — the
 * backend answers `403` to a cookie-session write without it. The header is
 * added in the preview branch too: that request rides a Bearer token beside
 * the ambient session cookie, so the server-side non-ambient exemption does
 * not apply.
 *
 * @param input              Request URL (relative, e.g. `/Api/iam/me`).
 * @param init               Standard `RequestInit`.
 * @param opts.fetch         Inject a fetch implementation (pass SvelteKit's
 *                           `event.fetch` from universal load functions so
 *                           cookies are forwarded during SSR). Defaults to
 *                           the global `fetch`.
 * @param opts.redirectOnFailure  When `true` (default), a failed refresh
 *                           redirects the browser to `/Login` with the
 *                           current path as `redirectTo` (see
 *                           `loginRedirect.ts`) via `window.location`. When
 *                           `false`, the 401 `Response` is returned and the
 *                           caller is responsible for handling the failure
 *                           (used by the universal layout load, which
 *                           redirects via SvelteKit's `throw redirect`).
 * @param opts.attemptRefresh   When `true` (default), `apiFetch` performs
 *                           pre-emptive and reactive (401) token refresh.
 *                           When `false`, both are skipped and the raw
 *                           `Response` is returned — use this for endpoints
 *                           where a 401 is an expected outcome rather than
 *                           a session-expiry signal (e.g. `/Api/iam/login`
 *                           returns 401 for bad credentials, and
 *                           `/Api/iam/me` on the login route returns 401
 *                           for a not-yet-authenticated visitor). Treating
 *                           those 401s as recoverable would trigger a
 *                           pointless refresh and, for browser callers, a
 *                           reload loop back to `/Login`.
 */
export async function apiFetch(
	input: string,
	init?: RequestInit,
	opts?: { fetch?: typeof fetch; redirectOnFailure?: boolean; attemptRefresh?: boolean }
): Promise<Response> {
	const fetchFn = opts?.fetch ?? fetch;
	const redirectOnFailure = opts?.redirectOnFailure ?? true;
	const attemptRefresh = opts?.attemptRefresh ?? true;

	const method = (init?.method ?? 'GET').toUpperCase();
	const headers = withCsrfHeader(init?.headers, method);

	// Preview-session overlay: when a preview capability token is active, it
	// replaces the cookie as the auth source for every request. The regular
	// pre-emptive refresh + 401-recovery flow is skipped — the preview token
	// has no refresh-token companion, so its 401 means the draft was published/
	// dropped or the TTL elapsed, and the user must restart the preview.
	const preview = getPreviewSession();
	if (preview) {
		const previewHeaders = new Headers(headers);
		previewHeaders.set('Authorization', `Bearer ${preview.token}`);
		// An expiring preview token is *not* auto-renewed by `/Api/iam/refresh`:
		// refresh is bound to the cookie-session. We let the request fly with
		// the token as-is; if the backend rejects with 401 we clear the
		// preview session and surface the response.
		const res = await fetchFn(input, { ...init, headers: previewHeaders, credentials: 'include' });
		if (res.status === 401) {
			// The preview token is dead. Drop the overlay so subsequent calls
			// (e.g. invalidation/the redirect back to Builder) use the cookie
			// session again. The caller decides how to surface this; a layout-
			// level redirect-to-Builder handler reads `isPreviewActive()` on
			// navigation to detect the dropped session.
			clearPreviewSession();
		}
		return res;
	}

	// Pre-emptive refresh runs only on the client (where `expiresAt` is tracked
	// per tab). On the server `expiresAt` is always null — see `setExpiresAt` —
	// so this branch is skipped and 401 recovery (below) handles expiry.
	const now = Math.floor(Date.now() / 1000);
	const expiry = getExpiresAt();
	if (attemptRefresh && expiry !== null && expiry - now < REFRESH_THRESHOLD) {
		const refreshed = await tryRefresh(fetchFn);
		if (!refreshed) return authFailure(redirectOnFailure);
	}

	const res = await fetchFn(input, { ...init, headers, credentials: 'include' });

	// A 401 on an auth endpoint (e.g. bad credentials on `/Api/iam/login`, or a
	// not-logged-in visitor hitting `/Api/iam/me` on `/Login`) is an expected
	// outcome, not a recoverable session-expiry. Only authenticated callers
	// opt into 401-recovery via `attemptRefresh: true` (the default).
	if (attemptRefresh && res.status === 401) {
		const refreshed = await tryRefresh(fetchFn);
		if (refreshed) {
			return fetchFn(input, { ...init, headers, credentials: 'include' });
		}
		return authFailure(redirectOnFailure);
	}

	return res;
}

const CSRF_HEADER = 'X-Requested-With';
const CSRF_HEADER_VALUE = 'XMLHttpRequest';
const MUTATING_METHODS = new Set(['POST', 'PATCH', 'PUT', 'DELETE']);

/**
 * Adds the CSRF header to a mutating request when the caller has not set
 * one. Non-mutating methods keep the caller's headers untouched.
 */
function withCsrfHeader(headers: HeadersInit | undefined, method: string): HeadersInit | undefined {
	if (!MUTATING_METHODS.has(method)) return headers;
	const merged = new Headers(headers);
	if (merged.has(CSRF_HEADER)) return headers;
	merged.set(CSRF_HEADER, CSRF_HEADER_VALUE);
	return merged;
}

/**
 * Redirects the browser to `/Login`, carrying the current path + query as the
 * post-login return target. No-op during SSR.
 *
 * Shared by the HTTP 401 path (`authFailure`) and the WebSocket client, which
 * stops reconnecting and calls this when the upgrade is refused for a dead
 * session.
 */
export function redirectToLogin(): void {
	if (typeof window === 'undefined') return;
	// Carry the current path + query so the login page can return the user
	// here after sign-in — the same URL shape the SSR hook builds (see
	// `loginRedirect.ts`).
	window.location.href = buildLoginRedirect(window.location.pathname + window.location.search);
}

function authFailure(redirect: boolean): Response {
	if (redirect) redirectToLogin();
	return new Response(null, { status: 401 });
}
