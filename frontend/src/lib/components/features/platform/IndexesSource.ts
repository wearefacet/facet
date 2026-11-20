// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { apiFetch } from '$lib/session.svelte.js';
import { serializeFilterValue } from '$lib/datasource/filterParams.js';

/**
 * Managed-index status data plumbing — `GET /Api/Indexes`.
 *
 * Pure adapter logic: query building, response parsing, and error mapping,
 * so the table component and the page stay pure renderers. Same shape as
 * the audit source (`AuditSource.ts`): the fetcher is injectable so
 * pure-logic tests can stub responses without touching the session layer.
 */

/** Lifecycle status of one managed index (`doctype_indexes.status`). */
export type IndexStatus = 'pending' | 'active' | 'error' | 'dropped';

/** One row of `doctype_indexes` as returned by the backend. */
export interface IndexRow {
	id: string;
	domain: string;
	doc_type: string;
	field_name: string;
	index_type: string;
	index_name: string;
	status: IndexStatus;
	error_message: string | null;
	created_at: string;
	updated_at: string;
}

/** Response of `GET /Api/Indexes` — the platform `{ data, meta }` shape. */
export interface IndexListResponse {
	data: IndexRow[];
	meta: { count: number; more: boolean };
}

/** Params for the index list — same grammar as the audit list. */
export interface IndexListParams {
	page?: number;
	items?: number;
	filters?: Record<string, unknown>;
	sort?: string[];
}

/** Typed error carrying the HTTP status so the page can render 403 distinctly. */
export class IndexesError extends Error {
	status: number;

	constructor(status: number, message: string) {
		super(message);
		this.name = 'IndexesError';
		this.status = status;
	}
}

/** Build the query string for `GET /Api/Indexes` from list params. */
export function buildIndexesQuery(params: IndexListParams): string {
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
export type IndexesFetch = (input: string, init?: RequestInit) => Promise<Response>;

/**
 * Fetch the managed-index list. Throws {@link IndexesError} with the HTTP
 * status on failure so callers can render `403` (no wildcard read
 * permission) or other statuses distinctly.
 */
export async function listIndexes(
	params: IndexListParams = {},
	fetchFn: IndexesFetch = apiFetch
): Promise<IndexListResponse> {
	const qs = buildIndexesQuery(params);
	const url = qs ? `/Api/Indexes?${qs}` : '/Api/Indexes';
	const res = await fetchFn(url);
	if (!res.ok) {
		const message = await parseErrorMessage(res);
		throw new IndexesError(res.status, message);
	}
	return (await res.json()) as IndexListResponse;
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
