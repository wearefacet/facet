// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { apiFetch } from '$lib/session.svelte.js';
import type { HistoryResponse, RollbackResponse } from '$lib/datasource/types.js';
import { serializeFilterValue } from '$lib/datasource/filterParams.js';

/**
 * Global audit log data plumbing — `GET /Api/Audit` and the global rollback
 * endpoint. Pure adapter logic: query building, response parsing, and error
 * mapping, so the table/detail components and the page stay pure renderers.
 *
 * The fetcher is injectable so pure-logic tests can stub responses without
 * touching the session layer.
 */

/** Params for the global audit list — mirrors `HistoryParams`. */
export interface AuditListParams {
	page?: number;
	items?: number;
	filters?: Record<string, unknown>;
	sort?: string[];
}

/** Typed error carrying the HTTP status so the page can render 403/422 distinctly. */
export class AuditError extends Error {
	status: number;

	constructor(status: number, message: string) {
		super(message);
		this.name = 'AuditError';
		this.status = status;
	}
}

/** Build the query string for `GET /Api/Audit` from list params. */
export function buildAuditQuery(params: AuditListParams): string {
	const query = new URLSearchParams();
	if (params?.page) query.set('page', String(params.page));
	if (params?.items) query.set('items', String(params.items));
	if (params?.sort && params.sort.length > 0) query.set('sort', params.sort.join(','));
	if (params?.filters) {
		for (const [k, v] of Object.entries(params.filters)) {
			if (v === '' || v == null) continue;
			query.set(`filters[${k}]`, serializeFilterValue(v));
		}
	}
	return query.toString();
}

/** apiFetch-compatible signature: string URL input, optional init. */
export type AuditFetch = (input: string, init?: RequestInit) => Promise<Response>;

/**
 * Fetch the global audit log. Throws {@link AuditError} with the HTTP status
 * on failure so callers can render `403` (no wildcard read permission) or
 * other statuses distinctly.
 */
export async function listAudit(
	params: AuditListParams = {},
	fetchFn: AuditFetch = apiFetch
): Promise<HistoryResponse> {
	const qs = buildAuditQuery(params);
	const url = qs ? `/Api/Audit?${qs}` : '/Api/Audit';
	const res = await fetchFn(url);
	if (!res.ok) {
		const message = await parseErrorMessage(res);
		throw new AuditError(res.status, message);
	}
	return (await res.json()) as HistoryResponse;
}

/**
 * Roll back to a specific mutation via the global rollback endpoint.
 * Surfaces `403` / `422` messages verbatim (the backend messages explain the
 * tombstone rule and permission failures).
 */
export async function rollbackMutation(
	mutationId: string,
	fetchFn: AuditFetch = apiFetch
): Promise<RollbackResponse> {
	const res = await fetchFn(`/Api/Audit/${encodeURIComponent(mutationId)}/rollback`, {
		method: 'POST'
	});
	if (!res.ok) {
		const message = await parseErrorMessage(res);
		throw new AuditError(res.status, message);
	}
	return (await res.json()) as RollbackResponse;
}

/** One document's undo inside a cluster rollback. */
export interface RollbackClusterDocument {
	domain: string;
	doc_type: string;
	doc_id: string;
	mut_id: string;
	/** `restored` — replayed to the pre-action state; `deleted` — created by the action. */
	outcome: string;
}

/** Response of a cluster-scope rollback (`scope: "cluster"`). */
export interface RollbackClusterResponse {
	trace: string;
	count: number;
	documents: RollbackClusterDocument[];
}

/**
 * Roll back a whole causal cluster (an action with its nested writes, or a
 * cascade subtree): every document the cluster touched is restored to its
 * pre-action state, in one backend transaction.
 */
export async function rollbackCluster(
	mutationId: string,
	fetchFn: AuditFetch = apiFetch
): Promise<RollbackClusterResponse> {
	const res = await fetchFn(`/Api/Audit/${encodeURIComponent(mutationId)}/rollback`, {
		method: 'POST',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify({ scope: 'cluster' })
	});
	if (!res.ok) {
		const message = await parseErrorMessage(res);
		throw new AuditError(res.status, message);
	}
	return (await res.json()) as RollbackClusterResponse;
}

/** Extract a backend error message, falling back to a status-based default. */
async function parseErrorMessage(res: Response): Promise<string> {
	try {
		const body = (await res.json()) as { error?: string; message?: string };
		return body.error ?? body.message ?? res.statusText;
	} catch {
		return res.statusText || 'Request failed';
	}
}
