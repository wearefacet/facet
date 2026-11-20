// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

// Thin client for the app API key endpoints (backend `confidential` apps).
//
// Backend: `src/app/routes.cr` —
//   POST   /Api/app/:id/api-key   issue (rotates any active key)
//   GET    /Api/app/:id/api-key   status of the app's key
//   DELETE /Api/app/:id/api-key   revoke (idempotent)
//
// The raw key is returned exactly once, on issue. Every write is
// CSRF-checked server-side, so the `X-Requested-With` header is sent here.

import { apiFetch } from '$lib/session.svelte';
import { apiErrorMessage } from '$lib/http.js';
import * as m from '$lib/paraglide/messages';

export interface IssuedAppKey {
	id: string;
	/** The raw key (`fct_` + 26 chars) — shown once, never stored client-side. */
	key: string;
	display_prefix: string;
	/** `iam.Account` id of the app's service account, created or reused on issue. */
	service_account_id: string;
	/** Qualified `iam.Roles` id the key authenticates as. */
	role_id: string;
}

export interface ActiveAppKey {
	id: string;
	/** Key prefix that identifies the key without the secret. */
	display_prefix: string;
	role_id: string;
	created_at: string;
	last_used_at: string | null;
}

export type AppKeyStatus = ({ active: true } & ActiveAppKey) | { active: false };

type FetchFn = typeof fetch;

function appKeyUrl(appId: string): string {
	return `/Api/app/${encodeURIComponent(appId)}/api-key`;
}

export async function issueAppKey(appId: string, fetchFn?: FetchFn): Promise<IssuedAppKey> {
	const res = await apiFetch(
		appKeyUrl(appId),
		{
			method: 'POST',
			headers: { 'X-Requested-With': 'XMLHttpRequest' }
		},
		{ fetch: fetchFn }
	);
	if (!res.ok) throw await apiErrorMessage(res, m.errors_app_key_issue());
	return (await res.json()) as IssuedAppKey;
}

export async function getAppKey(appId: string, fetchFn?: FetchFn): Promise<AppKeyStatus> {
	const res = await apiFetch(appKeyUrl(appId), {}, { fetch: fetchFn });
	if (!res.ok) throw await apiErrorMessage(res, m.errors_app_key_status());
	return (await res.json()) as AppKeyStatus;
}

export async function revokeAppKey(appId: string, fetchFn?: FetchFn): Promise<boolean> {
	const res = await apiFetch(
		appKeyUrl(appId),
		{
			method: 'DELETE',
			headers: { 'X-Requested-With': 'XMLHttpRequest' }
		},
		{ fetch: fetchFn }
	);
	if (!res.ok) throw await apiErrorMessage(res, m.errors_api_key_revoke());
	return ((await res.json()) as { revoked: boolean }).revoked;
}
