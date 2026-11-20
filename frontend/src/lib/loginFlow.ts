// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Login flow — pure branch decoding.
 *
 * The IAM login endpoints answer with one of several held-login shapes on
 * HTTP 200. This module maps a response body to the next UI step without
 * touching the DOM, stores, or `fetch` — so the Vitest `server` project can
 * test every mapping in plain Node. It also holds the enroll-at-login
 * context persistence (F05-07): pure helpers that read and write a
 * caller-provided `Storage`, so the same server project pins them.
 *
 * Response shapes (see `src/iam/routes.cr`):
 *   - token body      → `{account, active_role, available_roles, expires_at, …}`
 *   - MFA challenge   → `{mfa: true, challenge_id, type: "totp"}`
 *   - forced change   → `{must_change_password: true, change_token}`
 *   - MFA enrollment  → `{mfa_enroll_required: true, enroll_token, secret, otpauth_uri, mfa_enforcement}`
 */
import * as m from '$lib/paraglide/messages';

/** Response body of a token-emitting IAM endpoint (cookie mode). */
export interface LoginTokenBody {
	account: {
		id: string;
		email: string;
		display_name: string;
		mfa_enabled: boolean;
		mfa_enforcement?: string;
	};
	active_role: string;
	available_roles: string[];
	expires_at: number;
	permissions?: Record<string, string[]>;
	scopes?: Record<string, string[]>;
}

/** MFA state of the signed-in user, from `GET /Api/iam/me`. */
export interface MeMfaState {
	mfa_enabled: boolean;
	mfa_enforcement: string;
	/** Server-side factor type (`iam.mfa.type`) — enrollment needs `totp`. */
	mfa_type: string;
}

/** One step of the held-login state machine, decoded from a response body. */
export type LoginBranch =
	| { kind: 'tokens'; body: LoginTokenBody }
	| { kind: 'mfa_challenge'; challengeId: string }
	| { kind: 'must_change_password'; changeToken: string }
	| {
			kind: 'mfa_enroll';
			enrollToken: string;
			secret: string;
			otpauthUri: string;
			enforcement: string;
	  };

/**
 * True when the body is a token-emitting response (the same shape for login,
 * challenge, enroll-verify, and reset-confirm auto-login).
 */
export function isTokenBody(body: unknown): body is LoginTokenBody {
	if (typeof body !== 'object' || body === null) return false;
	const b = body as Record<string, unknown>;
	return (
		typeof b.expires_at === 'number' &&
		typeof b.active_role === 'string' &&
		typeof b.account === 'object' &&
		b.account !== null
	);
}

/** Thrown when the backend rejects a login attempt. `remainingAttempts`
 * carries the brute-force counter the backend exposes on the 401 (B-139 —
 * the same Redis counter the MFA challenge path surfaces); `null` when the
 * response carried no count (e.g. an unknown email, or an older backend). */
export class LoginRejected extends Error {
	remainingAttempts: number | null;

	constructor(message: string, remainingAttempts: number | null = null) {
		super(message);
		this.remainingAttempts = remainingAttempts;
	}
}

/**
 * Maps a failed `POST /Api/iam/login` response body to a `LoginRejected`.
 * The message comes from the backend's `error` field (falling back to the
 * catalogue string); `remaining_attempts` rides through when present and
 * parseable. Pure so the Vitest `server` project can pin the decoding.
 */
export function decodeLoginError(body: unknown, fallback: string): LoginRejected {
	const b = typeof body === 'object' && body !== null ? (body as Record<string, unknown>) : {};
	const message = typeof b.error === 'string' ? b.error : fallback;
	const raw = b.remaining_attempts;
	const remaining = typeof raw === 'string' || typeof raw === 'number' ? Number(raw) : null;
	const parsed = remaining !== null && Number.isFinite(remaining) ? remaining : null;
	return new LoginRejected(message, parsed);
}

/**
 * Maps a `POST /Api/iam/login` response body to the next flow step. Throws
 * when the body matches no known shape — a silent fallthrough to the token
 * branch would strand the user on a broken session.
 */
export function decodeLoginResponse(body: unknown): LoginBranch {
	if (typeof body !== 'object' || body === null) {
		throw new Error(m.auth_login_unrecognized());
	}
	const b = body as Record<string, unknown>;

	if (b.mfa_enroll_required === true) {
		if (
			typeof b.enroll_token !== 'string' ||
			typeof b.secret !== 'string' ||
			typeof b.otpauth_uri !== 'string'
		) {
			throw new Error(m.auth_login_unrecognized());
		}
		return {
			kind: 'mfa_enroll',
			enrollToken: b.enroll_token,
			secret: b.secret,
			otpauthUri: b.otpauth_uri,
			enforcement: typeof b.mfa_enforcement === 'string' ? b.mfa_enforcement : 'always'
		};
	}

	if (b.mfa === true) {
		if (typeof b.challenge_id !== 'string') throw new Error(m.auth_login_unrecognized());
		return { kind: 'mfa_challenge', challengeId: b.challenge_id };
	}

	if (b.must_change_password === true) {
		if (typeof b.change_token !== 'string') throw new Error(m.auth_login_unrecognized());
		return { kind: 'must_change_password', changeToken: b.change_token };
	}

	if (isTokenBody(body)) return { kind: 'tokens', body };

	throw new Error(m.auth_login_unrecognized());
}

/**
 * Enrollment prompt gate for the `preferred` enforcement mode: the prompt
 * shows only when the account is not enrolled **and** the server runs TOTP
 * at all (`mfa_type: "none"` makes setup answer `422` — probing it from the
 * login flow would only add console noise). Under `always` the backend
 * holds the login itself (enroll branch), so this never fires there.
 */
export function shouldPromptEnrollment(me: MeMfaState): boolean {
	return me.mfa_type === 'totp' && me.mfa_enforcement === 'preferred' && me.mfa_enabled === false;
}

/**
 * Enroll-at-login context persistence (F05-07).
 *
 * Under `always` enforcement the login withholds the session and hands out
 * a one-shot enroll token. A reload used to lose that context and force a
 * fresh sign-in. These helpers keep the minimal enroll payload in
 * `sessionStorage` (tab-scoped, cleared when the tab closes) so the enroll
 * step can resume after a reload.
 *
 * The Redis `enroll:{token}` hash (TTL 300 s) stays the server-side anchor:
 * a stale stored token simply fails verify with 401. The `savedAt` mirror
 * only drops clearly dead entries client-side — no extra endpoint, and no
 * matching on backend error strings.
 *
 * Security: the payload equals what the page already holds in memory while
 * the enroll screen is up. `sessionStorage` adds no new exposure class —
 * it is tab-local, never sent to the server, and cleared as soon as the
 * flow completes or resets.
 */
export interface PersistedEnrollContext {
	enrollToken: string;
	secret: string;
	otpauthUri: string;
	/** `Date.now()` when the context was written — client mirror of the server TTL. */
	savedAt: number;
}

/** The three fields the page needs to re-render the enroll step. */
export type EnrollContext = Pick<PersistedEnrollContext, 'enrollToken' | 'secret' | 'otpauthUri'>;

/** sessionStorage key that holds the enroll-at-login context. */
export const ENROLL_CONTEXT_KEY = 'facet.enroll-at-login';

/** Client mirror of the server enroll-token TTL (`EnrollToken::ENROLL_TTL`). */
export const ENROLL_CONTEXT_TTL_MS = 300_000;

/** Writes the enroll context for the current tab. Only the three needed
 * fields are stored — a caller may pass a wider object (e.g. a decoded
 * login branch) and the extra fields stay out of storage. Storage failures
 * (quota, privacy mode) are swallowed — the flow keeps its in-memory state,
 * and a reload then behaves as before the fix. */
export function saveEnrollContext(storage: Storage, context: EnrollContext, now: number): void {
	const payload: PersistedEnrollContext = {
		enrollToken: context.enrollToken,
		secret: context.secret,
		otpauthUri: context.otpauthUri,
		savedAt: now
	};
	try {
		storage.setItem(ENROLL_CONTEXT_KEY, JSON.stringify(payload));
	} catch {
		/* persistence is best-effort */
	}
}

/** True when the client TTL mirror says the enroll token is past the server
 * TTL. The mirror starts at the save, which is at or after the server-side
 * token creation, so this never fires before the server expiry. */
export function isEnrollContextExpired(savedAt: number, now: number): boolean {
	return now - savedAt >= ENROLL_CONTEXT_TTL_MS;
}

/** Removes the persisted enroll context. */
export function clearEnrollContext(storage: Storage): void {
	try {
		storage.removeItem(ENROLL_CONTEXT_KEY);
	} catch {
		/* nothing to undo */
	}
}

/** Reads the enroll context back. Returns `null` — and removes the stored
 * entry — when it is absent, corrupt, wrongly shaped, or past the TTL, so
 * every caller lands in a clean state. */
export function loadEnrollContext(storage: Storage, now: number): PersistedEnrollContext | null {
	let raw: string | null;
	try {
		raw = storage.getItem(ENROLL_CONTEXT_KEY);
	} catch {
		return null;
	}
	if (raw === null) return null;
	try {
		const context = parseEnrollContext(JSON.parse(raw));
		if (context !== null && !isEnrollContextExpired(context.savedAt, now)) return context;
	} catch {
		/* fall through to the remove below */
	}
	clearEnrollContext(storage);
	return null;
}

/** Shape check for a stored payload. Returns `null` for junk. */
function parseEnrollContext(value: unknown): PersistedEnrollContext | null {
	if (typeof value !== 'object' || value === null) return null;
	const v = value as Record<string, unknown>;
	if (typeof v.enrollToken !== 'string' || v.enrollToken === '') return null;
	if (typeof v.secret !== 'string' || v.secret === '') return null;
	if (typeof v.otpauthUri !== 'string' || v.otpauthUri === '') return null;
	if (typeof v.savedAt !== 'number' || !Number.isFinite(v.savedAt)) return null;
	return {
		enrollToken: v.enrollToken,
		secret: v.secret,
		otpauthUri: v.otpauthUri,
		savedAt: v.savedAt
	};
}
