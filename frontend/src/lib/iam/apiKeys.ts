// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

// Thin client for the self-service API key endpoints.
//
// Backend: `src/iam/routes.cr` —
//   POST   /Api/iam/keys        create (name, role, optional expires_at)
//   GET    /Api/iam/keys        list the caller's keys (no secret)
//   DELETE /Api/iam/keys/:id    soft-revoke (idempotent)
//
// The raw key is returned exactly once, on create. Every write is
// CSRF-checked server-side, so the `X-Requested-With` header is sent here.

import { apiFetch } from '$lib/session.svelte';
import { apiErrorMessage } from '$lib/http.js';
import * as m from '$lib/paraglide/messages';

export interface ApiKeyRecord {
	id: string;
	name: string;
	/** `fct_` + the first 6 secret chars — identifies the key without the secret. */
	display_prefix: string;
	/** Role document id (`iam.Roles.{name}`). */
	role_id: string;
	created_at: string;
	expires_at: string | null;
	last_used_at: string | null;
	revoked_at: string | null;
}

export interface CreatedApiKey {
	id: string;
	/** The raw key (`fct_` + 26 chars) — shown once, never stored client-side. */
	key: string;
	display_prefix: string;
	expires_at: string | null;
}

export interface CreateApiKeyInput {
	name: string;
	role: string;
	/** UTC RFC-3339 datetime; must be in the future when present. */
	expires_at?: string;
}

type FetchFn = typeof fetch;

export async function listApiKeys(fetchFn?: FetchFn): Promise<ApiKeyRecord[]> {
	const res = await apiFetch('/Api/iam/keys', {}, { fetch: fetchFn });
	if (!res.ok) throw await apiErrorMessage(res, m.errors_api_keys_load());
	return (await res.json()) as ApiKeyRecord[];
}

export async function createApiKey(
	input: CreateApiKeyInput,
	fetchFn?: FetchFn
): Promise<CreatedApiKey> {
	const res = await apiFetch(
		'/Api/iam/keys',
		{
			method: 'POST',
			headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest' },
			body: JSON.stringify(input)
		},
		{ fetch: fetchFn }
	);
	if (!res.ok) throw await apiErrorMessage(res, m.errors_api_key_create());
	return (await res.json()) as CreatedApiKey;
}

export async function revokeApiKey(keyId: string, fetchFn?: FetchFn): Promise<void> {
	const res = await apiFetch(
		`/Api/iam/keys/${encodeURIComponent(keyId)}`,
		{
			method: 'DELETE',
			headers: { 'X-Requested-With': 'XMLHttpRequest' }
		},
		{ fetch: fetchFn }
	);
	if (!res.ok) throw await apiErrorMessage(res, m.errors_api_key_revoke());
}
