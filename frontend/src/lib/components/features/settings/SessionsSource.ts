// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

// Thin client for the account's own session endpoints (B-140).
//
// Backend: `src/iam/routes.cr` —
//   GET    /Api/iam/sessions           list the caller's sessions (ids + metadata, no tokens)
//   DELETE /Api/iam/sessions/:id       revoke one own session (idempotent; ownership-gated)
//   DELETE /Api/iam/sessions           revoke every session EXCEPT the caller's current one
//
// Both DELETEs are CSRF-checked server-side; `apiFetch` adds the
// `X-Requested-With` header to every mutating call. The list never carries
// refresh tokens — ids and metadata only.

import { apiFetch } from '$lib/session.svelte';
import { apiErrorMessage } from '$lib/http.js';
import * as m from '$lib/paraglide/messages';

/** One entry of `GET /Api/iam/sessions`. */
export interface AccountSession {
	session_id: string;
	/** RFC-3339 UTC string — set when the session was created. */
	created_at: string;
	/** RFC-3339 UTC string — set at creation and on every token refresh. */
	last_used: string;
	user_agent: string | null;
	ip: string | null;
	/** `app.App` projection id for an app session; `null` for a browser session. */
	app: string | null;
	/** The session's active role id (`iam.Roles.editor`). */
	role: string;
}

type FetchFn = typeof fetch;

export async function listSessions(fetchFn?: FetchFn): Promise<AccountSession[]> {
	const res = await apiFetch('/Api/iam/sessions', {}, { fetch: fetchFn });
	if (!res.ok) throw await apiErrorMessage(res, m.errors_sessions_load());
	const body = (await res.json()) as { sessions?: AccountSession[] };
	return body.sessions ?? [];
}

export async function revokeSession(sessionId: string, fetchFn?: FetchFn): Promise<void> {
	const res = await apiFetch(
		`/Api/iam/sessions/${encodeURIComponent(sessionId)}`,
		{ method: 'DELETE' },
		{ fetch: fetchFn }
	);
	if (!res.ok) throw await apiErrorMessage(res, m.errors_session_revoke());
}

/**
 * Revokes every other session and returns the count the backend reports.
 * The caller's current session is excluded server-side.
 */
export async function revokeAllSessions(fetchFn?: FetchFn): Promise<number> {
	const res = await apiFetch('/Api/iam/sessions', { method: 'DELETE' }, { fetch: fetchFn });
	if (!res.ok) throw await apiErrorMessage(res, m.errors_sessions_revoke_all());
	const body = (await res.json()) as { revoked?: number };
	return body.revoked ?? 0;
}
