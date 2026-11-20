// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { apiFetch } from '$lib/session.svelte.js';

/**
 * OIDC provider data plumbing — the admin surface over the standard
 * document routes for `iam.OIDCProvider` (see `doc/backend/oidc.md`).
 *
 * Pure adapter logic in the same shape as `SystemSettingsSource.ts`: the
 * fetcher is injectable so stories can stub responses without touching
 * the session layer. Writes go through the standard document routes
 * (`POST/PATCH/DELETE /Api/iam/OIDCProvider...`) — RBAC, the Lua lifecycle
 * validation, and the event fanout all apply server-side. The client
 * secret is staged out-of-band (`POST /Api/secrets/stage`) and the PATCH
 * carries the single-use handle — the plaintext never enters a document
 * body.
 */

/** The public providers read the login page uses (`{auth_mode, providers}`). */
export interface OidcProvidersResponse {
	auth_mode: 'hybrid' | 'oidc_only';
	providers: { name: string; label: string }[];
}

/** One provider row as the document list/show routes serialize it. */
export interface OidcProviderRow {
	id: string;
	name: string;
	label: string;
	issuer: string;
	client_id: string;
	/** `secret` fields serialize as the adoption marker or null — never a value. */
	client_secret: { mode: string; version: number; set_at: string } | null;
	domains: string[];
	default_role: string | null;
	auto_provision: boolean;
	scopes: string[];
	enabled: boolean;
}

/** Typed error carrying the HTTP status and the parsed `422` field details. */
export class OidcProvidersError extends Error {
	status: number;
	fieldErrors: { field: string | null; message: string; code: string | null }[];

	constructor(
		status: number,
		message: string,
		fieldErrors: { field: string | null; message: string; code: string | null }[] = []
	) {
		super(message);
		this.name = 'OidcProvidersError';
		this.status = status;
		this.fieldErrors = fieldErrors;
	}
}

/** apiFetch-compatible signature: string URL input, optional init. */
export type OidcProvidersFetch = (input: string, init?: RequestInit) => Promise<Response>;

/** Parse a `422` body's `details` array into structured field errors. */
function parseFieldErrors(
	body: unknown
): { field: string | null; message: string; code: string | null }[] {
	const details = (body as { details?: unknown })?.details;
	if (!Array.isArray(details)) return [];
	return details
		.filter((d): d is Record<string, unknown> => typeof d === 'object' && d !== null)
		.map((d) => ({
			field: typeof d.field === 'string' ? d.field : null,
			message: typeof d.message === 'string' ? d.message : String(d.message ?? ''),
			code: typeof d.code === 'string' ? d.code : null
		}));
}

/** Build a JSON + CSRF header set for the state-changing calls. */
function jsonHeaders(): HeadersInit {
	return { 'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest' };
}

async function raise(res: Response): Promise<never> {
	let body: unknown = null;
	try {
		body = await res.json();
	} catch {
		// non-JSON error body — fall back to the status text
	}
	const message =
		(body as { error?: string; message?: string } | null)?.error ??
		(body as { error?: string; message?: string } | null)?.message ??
		res.statusText;
	throw new OidcProvidersError(
		res.status,
		message,
		res.status === 422 ? parseFieldErrors(body) : []
	);
}

/**
 * Lists the provider documents (admin read over the standard list route).
 *
 * The route answers the standard document list envelope
 * `{data: [{data, meta}], meta: {count, more}}` — the content fields nest
 * under each row's `data` and the document id lives in `meta.id` (B-196).
 * Rows are flattened to `{...content, id}` so the page and dialog read flat
 * fields. An unexpected envelope logs a warning and yields no rows, so the
 * page shows its empty state instead of silently rendering a wrong parse.
 */
export async function listProviders(
	fetchFn: OidcProvidersFetch = apiFetch
): Promise<OidcProviderRow[]> {
	const res = await fetchFn('/Api/iam/OIDCProvider', { headers: { Accept: 'application/json' } });
	if (!res.ok) await raise(res);
	const body = (await res.json()) as { data?: unknown };
	if (!Array.isArray(body.data)) {
		console.warn('listProviders: unexpected list envelope, showing no providers', body);
		return [];
	}
	const rows: OidcProviderRow[] = [];
	for (const item of body.data) {
		if (typeof item !== 'object' || item === null) continue;
		const { data, meta } = item as { data?: Record<string, unknown>; meta?: { id?: string } };
		if (typeof meta?.id !== 'string' || meta.id.length === 0) continue;
		rows.push({ ...(data ?? {}), id: meta.id } as OidcProviderRow);
	}
	return rows;
}

/** Fetches one provider document. */
export async function getProvider(
	id: string,
	fetchFn: OidcProvidersFetch = apiFetch
): Promise<OidcProviderRow> {
	const res = await fetchFn(`/Api/iam/OIDCProvider/${id}`);
	if (!res.ok) await raise(res);
	return (await res.json()) as OidcProviderRow;
}

/**
 * Stages the client-secret plaintext out-of-band and returns the
 * single-use handle. The editor dialog puts the handle into the create /
 * PATCH body; the write pipeline adopts it into the sealed store and
 * substitutes the marker.
 */
export async function stageClientSecret(
	value: string,
	fetchFn: OidcProvidersFetch = apiFetch
): Promise<string> {
	const res = await fetchFn('/Api/secrets/stage', {
		method: 'POST',
		headers: jsonHeaders(),
		body: JSON.stringify({
			domain: 'iam',
			doctype: 'OIDCProvider',
			field_path: 'client_secret',
			value
		})
	});
	if (!res.ok) await raise(res);
	const body = (await res.json()) as { handle: string };
	return body.handle;
}

/** Creates one provider. `fields.client_secret` must already be a stage handle. */
export async function createProvider(
	fields: Record<string, unknown>,
	fetchFn: OidcProvidersFetch = apiFetch
): Promise<void> {
	const res = await fetchFn('/Api/iam/OIDCProvider', {
		method: 'POST',
		headers: jsonHeaders(),
		body: JSON.stringify(fields)
	});
	if (!res.ok) await raise(res);
}

/** Sparse-updates one provider. `fields.client_secret` must already be a stage handle. */
export async function updateProvider(
	id: string,
	fields: Record<string, unknown>,
	fetchFn: OidcProvidersFetch = apiFetch
): Promise<void> {
	const res = await fetchFn(`/Api/iam/OIDCProvider/${id}`, {
		method: 'PATCH',
		headers: jsonHeaders(),
		body: JSON.stringify(fields)
	});
	if (!res.ok) await raise(res);
}

/** Deletes one provider (tombstone). Idempotent at the document layer. */
export async function deleteProvider(
	id: string,
	fetchFn: OidcProvidersFetch = apiFetch
): Promise<void> {
	const res = await fetchFn(`/Api/iam/OIDCProvider/${id}`, {
		method: 'DELETE',
		headers: jsonHeaders()
	});
	if (!res.ok) await raise(res);
}
