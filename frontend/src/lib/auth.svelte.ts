// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Auth client — login and logout flows.
 *
 * Uses HttpOnly cookies for token transport. The backend sets `auth_token`
 * and `refresh_token` cookies on login/refresh and clears them on logout.
 * The frontend never touches the token values directly — it only tracks
 * `expires_at` (returned in every login/refresh response) via
 * `session.svelte.ts`.
 *
 * Session validation and account profile fetching happen via
 * `GET /Api/iam/me`
 * in `+layout.ts` (universal load). This module is only for the login/logout
 * actions triggered from the UI.
 *
 * CSRF: all state-changing IAM requests send the `X-Requested-With` header,
 * enforced by the backend's `csrf_check`.
 */

import { apiFetch, setExpiresAt } from './session.svelte';
import * as m from '$lib/paraglide/messages';
import { setRole } from './role.svelte';
import { setPermissions, setScopes, setVisibleTags } from './permissions.svelte';
import { invalidateAllClientCaches } from './datasource/clientCache.js';
import { clearCounts } from './navCounts.svelte';
import { resetNotifications } from './notifications.svelte';
import { clearRecentDocuments } from './recentDocuments.svelte';
import { invalidateAll } from '$app/navigation';
import {
	decodeLoginError,
	decodeLoginResponse,
	isTokenBody,
	LoginRejected,
	type LoginBranch,
	type LoginTokenBody
} from './loginFlow';

/** MFA state of the signed-in account (subset of `GET /Api/iam/me`). */
export interface MeMfaState {
	email: string;
	mfa_enabled: boolean;
	mfa_enforcement: string;
	/** Server-side factor type (`iam.mfa.type`) — enrollment needs `totp`. */
	mfa_type: string;
}

/** Thrown by `confirmPasswordReset` when the link token is unknown or expired. */
export class ResetLinkError extends Error {}

const JSON_HEADERS = { 'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest' };

/** Reads the JSON body of a pre-auth IAM response, mapping errors to a thrown `Error`. */
async function expectOk(res: Response, fallback: string): Promise<Record<string, unknown>> {
	const body: unknown = await res.json();
	if (!res.ok) {
		const message =
			typeof body === 'object' &&
			body !== null &&
			typeof (body as Record<string, unknown>).error === 'string'
				? ((body as Record<string, unknown>).error as string)
				: fallback;
		throw new Error(message);
	}
	if (typeof body !== 'object' || body === null) throw new Error(fallback);
	return body as Record<string, unknown>;
}

/** Best-effort optimistic store write for a token-emitting response. */
function hydrateTokens(body: LoginTokenBody): LoginTokenBody {
	setExpiresAt(body.expires_at);
	setRole(body.active_role, body.available_roles);
	return body;
}
/** Re-exported for the login page's `instanceof` check — the class lives in
 * the pure `loginFlow` module so the error decoding stays Vitest-testable. */
export { LoginRejected };

/** Logs in with email + password. Cookies are set by the backend.
 *
 * `attemptRefresh: false` is passed because a 401 from `/Api/iam/login` means
 * "bad credentials", not "session expired". Opting out of `apiFetch`'s
 * 401-recovery avoids a pointless refresh attempt and (more importantly) the
 * reload-to-`/Login` fallback, so the login form can surface the error
 * message instead of reloading the page forever.
 *
 * The caller is expected to follow a successful login with either
 * `goto(target, { invalidateAll: true })` or `invalidateAll()`. `invalidateAll`
 * is the authoritative source of truth for the role/permissions/scopes stores:
 * it re-runs `+layout.ts`, which hydrates everything from a fresh `/Api/iam/me`
 * response. The local store updates in `hydrateTokens` are only a best-effort
 * optimistic write so UI elements tied to `getActiveRole()` / `getExpiresAt()`
 * flip instantly before the invalidate resolves — they are overwritten
 * (consistently) by the layout load a moment later.
 *
 * Returns a discriminated branch describing the next step of the flow:
 * `tokens` (hydrated and ready to enter the app), `mfa_challenge`,
 * `must_change_password`, or `mfa_enroll`. The held-login branches carry the
 * token / id the follow-up route needs. Throws with the backend error message
 * on a rejected login.
 */
export async function login(email: string, password: string): Promise<LoginBranch> {
	const res = await apiFetch(
		'/Api/iam/login',
		{
			method: 'POST',
			headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest' },
			body: JSON.stringify({ email, password, cookie: true })
		},
		{ attemptRefresh: false }
	);

	const body: unknown = await res.json();

	if (!res.ok) {
		throw decodeLoginError(body, m.auth_login_failed());
	}

	const branch = decodeLoginResponse(body);
	if (branch.kind === 'tokens') hydrateTokens(branch.body);
	return branch;
}

/** Completes an MFA challenge: posts `{challenge_id, result}` to
 * `/Api/iam/challenge` and hydrates the emitted session on success.
 * `method: 'backup_code'` verifies one of the single-use backup codes
 * instead of a TOTP code. Throws with the backend error message on a wrong
 * code or a dead challenge. */
export async function verifyChallenge(
	challengeId: string,
	code: string,
	method: 'totp' | 'backup_code' = 'totp'
): Promise<LoginTokenBody> {
	const res = await apiFetch(
		'/Api/iam/challenge',
		{
			method: 'POST',
			headers: JSON_HEADERS,
			body: JSON.stringify({ challenge_id: challengeId, result: code, method })
		},
		{ attemptRefresh: false }
	);
	const body = await expectOk(res, m.auth_verify_failed());
	if (!isTokenBody(body)) throw new Error(m.auth_verify_unexpected());
	return hydrateTokens(body);
}

/** Completes the enroll-at-login flow (`always` enforcement): posts the
 * one-shot `enroll_token` + first TOTP code to `/Api/iam/mfa/enroll/verify`
 * and hydrates the emitted session. The enroll token is single-use — a
 * wrong code consumes an attempt; a dead token requires a fresh login.
 * The response carries the account's single-use backup codes (shown once). */
export async function verifyEnroll(
	enrollToken: string,
	code: string
): Promise<{ body: LoginTokenBody; backupCodes: string[] }> {
	const res = await apiFetch(
		'/Api/iam/mfa/enroll/verify',
		{
			method: 'POST',
			headers: JSON_HEADERS,
			body: JSON.stringify({ enroll_token: enrollToken, code })
		},
		{ attemptRefresh: false }
	);
	const body = await expectOk(res, m.auth_verify_failed());
	if (!isTokenBody(body)) throw new Error(m.auth_verify_unexpected());
	return { body: hydrateTokens(body), backupCodes: extractBackupCodes(body) };
}

/** Changes the password through the one-shot bootstrap `change_token`
 * returned by the `must_change_password` login branch. Throws with the
 * backend error (wrong current password → 403, expired token → 401). */
export async function changePassword(
	changeToken: string,
	oldPassword: string,
	newPassword: string
): Promise<void> {
	const res = await apiFetch(
		'/Api/iam/change-password',
		{
			method: 'POST',
			headers: JSON_HEADERS,
			body: JSON.stringify({
				change_token: changeToken,
				old_password: oldPassword,
				new_password: newPassword
			})
		},
		{ attemptRefresh: false }
	);
	await expectOk(res, m.auth_password_change_failed());
}

/** Requests a password-reset link. The backend answers 200 regardless of
 * whether the identifier exists (anti-enumeration), so the caller always
 * shows the same "check your inbox" confirmation. Resolves with the
 * effective link TTL in seconds (`iam.change_password_expiration`) so the
 * confirmation copy can state the real validity window. */
export async function requestPasswordReset(
	identifier: string
): Promise<{ linkTtlSeconds: number }> {
	const res = await apiFetch(
		'/Api/iam/password-reset/request',
		{
			method: 'POST',
			headers: JSON_HEADERS,
			body: JSON.stringify({ email: identifier })
		},
		{ attemptRefresh: false }
	);
	const body = await expectOk(res, m.auth_reset_request_failed());
	if (typeof body.link_ttl_seconds !== 'number') {
		throw new Error(m.auth_reset_request_failed());
	}
	return { linkTtlSeconds: body.link_ttl_seconds };
}

/** Confirms a password reset with the link token. When the link set the
 * account's first credential, the backend emits a session and the response
 * is a token body (hydrated here); otherwise `{ok: true}`. Under MFA
 * `always` enforcement an un-enrolled first credential gets no session —
 * the body is `{ok: true}` and the sign-in that follows holds at
 * enrollment (B-141). Throws `ResetLinkError` when the token is unknown,
 * expired, or already used. */
export async function confirmPasswordReset(
	token: string,
	newPassword: string
): Promise<{ kind: 'tokens'; body: LoginTokenBody } | { kind: 'ok' }> {
	const res = await apiFetch(
		'/Api/iam/password-reset/confirm',
		{
			method: 'POST',
			headers: JSON_HEADERS,
			body: JSON.stringify({ token, new_password: newPassword, cookie: true })
		},
		{ attemptRefresh: false }
	);
	if (res.status === 401) throw new ResetLinkError(m.auth_reset_link_invalid());
	const body = await expectOk(res, m.auth_reset_failed());
	if (isTokenBody(body)) return { kind: 'tokens', body: hydrateTokens(body) };
	return { kind: 'ok' };
}

/** Fetches the signed-in user's MFA state from `/Api/iam/me`. */
export async function getMfaState(): Promise<MeMfaState> {
	const res = await apiFetch('/Api/iam/me');
	const body = await expectOk(res, m.auth_session_lookup_failed());
	const account = body.account as Record<string, unknown> | undefined;
	if (!account) throw new Error(m.auth_session_lookup_failed());
	return {
		email: typeof account.email === 'string' ? account.email : '',
		mfa_enabled: account.mfa_enabled === true,
		mfa_enforcement:
			typeof account.mfa_enforcement === 'string' ? account.mfa_enforcement : 'preferred',
		// `iam.mfa.type` defaults to `totp` server-side; mirror that so an
		// older payload keeps today's prompt behaviour.
		mfa_type: typeof account.mfa_type === 'string' ? account.mfa_type : 'totp'
	};
}

/** Starts TOTP enrollment for the signed-in user (session-authenticated
 * `preferred`-mode prompt): stores a provisional secret and returns it with
 * the `otpauth://` URI for the QR code. Safe to re-run — each call replaces
 * the provisional secret; `mfa_enabled` only flips on verify. */
export async function mfaSetup(account?: string): Promise<{ secret: string; otpauthUri: string }> {
	const res = await apiFetch('/Api/iam/mfa/totp/setup', {
		method: 'POST',
		headers: JSON_HEADERS,
		body: JSON.stringify(account ? { account } : {})
	});
	const body = await expectOk(res, m.auth_mfa_setup_failed());
	if (typeof body.secret !== 'string' || typeof body.otpauth_uri !== 'string') {
		throw new Error(m.auth_mfa_setup_unexpected());
	}
	return { secret: body.secret, otpauthUri: body.otpauth_uri };
}

/** Verifies the first TOTP code for the signed-in user and enables MFA.
 * Returns the account's single-use backup codes — the server mints them at
 * enrollment and they are shown exactly once. */
export async function verifyMfa(code: string): Promise<string[]> {
	const res = await apiFetch('/Api/iam/mfa/totp/verify', {
		method: 'POST',
		headers: JSON_HEADERS,
		body: JSON.stringify({ code })
	});
	const body = await expectOk(res, m.auth_verify_failed());
	return extractBackupCodes(body);
}

/** Reads the one-time `backup_codes` array off an enrollment response.
 * Empty when the server sent none — the UI then shows the honest empty
 * state instead of pretending codes exist. */
function extractBackupCodes(body: Record<string, unknown>): string[] {
	if (!Array.isArray(body.backup_codes)) return [];
	return body.backup_codes.filter((c): c is string => typeof c === 'string');
}

/** Logs out — clears cookies server-side, then redirects to /Login.
 *
 * `attemptRefresh: false`: logout needs no valid access token, and a 401 here
 * (already logged out) should not trigger a refresh / reload loop.
 *
 * After the server clears the cookies, `invalidateAll()` re-runs the root
 * layout's server load. `handleAuth` in `hooks.server.ts` sees the now-invalid
 * session and throws a 303 redirect to `/Login`, which SvelteKit follows. This
 * is what makes the root layout drop `AppShell` — a plain `goto('/Login')`
 * would keep the stale `authenticated: true` layout data (the root layout load
 * reads no URL, so it does not re-run on client-side navigation) and render
 * the login page inside the authenticated shell.
 */
export async function logout(): Promise<void> {
	await apiFetch(
		'/Api/iam/logout',
		{
			method: 'POST',
			headers: { 'X-Requested-With': 'XMLHttpRequest' }
		},
		{ attemptRefresh: false }
	);
	setExpiresAt(null);
	setRole(null, null);
	// Drop any cached API data so a subsequent login (possibly as a different
	// user) never sees the previous user's doctype definitions or documents.
	invalidateAllClientCaches();
	clearCounts();
	clearRecentDocuments();
	resetNotifications();
	await invalidateAll();
}

/** Switches the active role by requesting a role-bearing token refresh.
 *
 * The backend's `/Api/iam/refresh` accepts an optional `role` and, on success,
 * returns a new access token (cookie) plus the target role's permission &
 * scope manifests.
 *
 * State hydration is split into two layers, by design:
 *
 * 1. **Optimistic** (immediate, this function): write the fresh role / expiry /
 *    permissions / scopes into the module stores so the sidebar footer label
 *    and `<Can>` / `canScope()` gates flip instantly. Drop client caches so no
 *    stale document list (filtered by the previous role) is rendered.
 * 2. **Authoritative** (next tick, `invalidateAll()`): re-run the SvelteKit
 *    layout load. `+layout.server.ts` re-fetches `/Api/iam/me` (which re-reads
 *    the just-rotated session) and `+layout.ts` writes the result back into
 *    the same stores, plus rebuilds the nav model. `invalidateAll` is the
 *    single source of truth that keeps the layout's `data` snapshot (read as
 *    `data.activeRole` / `data.permissions` / `data.scopes` by various
 *    components) consistent with the store — without it, those `data` reads
 *    keep the previous role's snapshot and any consumer that prefers the
 *    `data` fallback (`getActiveRole() ?? data.activeRole` etc.) would see the
 *    old role until the next full page load.
 *
 * The `facet:permissions-update` window event is dispatched with no payload:
 * it is now a pure signal. The Configure pages and the root layout's handler
 * treat it as "reload everything you derived from the session" by calling
 * `invalidateAll()`. (It is still dispatched unconditionally on success so
 * any page that only listens — without re-reading `data` — also reloads after
 * a background auto-refresh that changed permissions.)
 *
 * Returns `true` on success, `false` when the backend rejects the switch
 * (e.g. the role is no longer assigned, or the session expired mid-switch).
 *
 * The optional `fetchFn` injects the request implementation (used by tests;
 * defaults to the global `fetch`).
 */
export async function switchActiveRole(
	role: string,
	fetchFn: typeof fetch = fetch
): Promise<boolean> {
	const res = await apiFetch(
		'/Api/iam/refresh',
		{
			method: 'POST',
			headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest' },
			body: JSON.stringify({ cookie: true, role }),
			credentials: 'include'
		},
		{ attemptRefresh: false, fetch: fetchFn }
	);
	if (!res.ok) return false;

	const body = await res.json();

	// 1. Optimistic store hydration. These writes are visible only in the
	//    browser; on SSR they no-op (module-level state is per-tab, gated on
	//    `typeof window`). `invalidateAll` below re-derives the same values
	//    authoritatively from `/Api/iam/me`.
	setExpiresAt(body.expires_at);
	setRole(body.active_role, body.available_roles);
	if (body.permissions) setPermissions(body.permissions);
	if (body.scopes) setScopes(body.scopes);
	// Same freshness contract as permissions/scopes: the refresh emit carries
	// the new role's field-tag visibility set (B-176), so the optimistic
	// phase never leaves a half-updated store behind.
	if (body.visible_tags) setVisibleTags(body.visible_tags);

	// Drop any cached API data so a subsequent list fetch hits the backend
	// under the new role. (`invalidateAll` re-runs every `load`, but the
	// datasource client cache is a separate layer from SvelteKit's `data`.)
	invalidateAllClientCaches();

	// 2. Authoritative re-hydration. Re-runs the root layout load, which calls
	//    `/Api/iam/me` (now seeing the rotated session) and feeds the result
	//    back into the role / permissions / scopes stores + rebuilds the nav
	//    model. Awaiting it means the caller sees the final state when this
	//    function resolves.
	if (typeof window !== 'undefined') {
		await invalidateAll();
	}

	return true;
}
