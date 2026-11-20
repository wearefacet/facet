// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { apiFetch } from '$lib/session.svelte.js';
import { serializeFilterValue } from '$lib/datasource/filterParams.js';

/**
 * Artifact admin data plumbing — `GET /Api/Artifacts` plus the
 * per-artifact grant / reference listings and grant revocation.
 *
 * Pure adapter logic: query building, response parsing, and error mapping,
 * so the explorer component and the page stay pure renderers. Same shape as
 * the indexes source (`IndexesSource.ts`): the fetcher is injectable so
 * pure-logic tests can stub responses without touching the session layer.
 */

/** One row of the artifact listing as returned by the backend. */
export interface ArtifactRow {
	id: string;
	filename: string;
	mime_type: string;
	size: number;
	sha256: string;
	deleted_at: string | null;
	created_at: string;
	/** Account id of the original uploader (earliest `artifact_owners` row); null for a system upload. */
	uploaded_by: string | null;
	owner_count: number;
	grant_count: number;
	reference_count: number;
}

/** One `artifact_grants` row of the per-artifact grant listing. */
export interface ArtifactGrantRow {
	id: string;
	artifact_id: string;
	owner_id: string;
	kind: 'ephemeral' | 'permanent';
	expires_at: string | null;
	epoch: number;
	created_by: string;
	created_at: string;
}

/** One `artifact_references` row joined with the referencing projection. */
export interface ArtifactReferenceRow {
	domain: string;
	doc_type: string | null;
	resource_id: string;
	display_name: string | null;
	resource_field: string;
	last_reference_at: string;
}

/** Platform `{ data, meta }` response shape. */
export interface ArtifactListResponse<T> {
	data: T[];
	meta: { count: number; more: boolean };
}

/** Params for the artifact list — same grammar as the index list. */
export interface ArtifactListParams {
	page?: number;
	items?: number;
	filters?: Record<string, unknown>;
	sort?: string[];
}

/** Typed error carrying the HTTP status so the page can render `403` distinctly. */
export class ArtifactsError extends Error {
	status: number;

	constructor(status: number, message: string) {
		super(message);
		this.name = 'ArtifactsError';
		this.status = status;
	}
}

/** Build the query string for `GET /Api/Artifacts` from list params. */
export function buildArtifactsQuery(params: ArtifactListParams): string {
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
export type ArtifactsFetch = (input: string, init?: RequestInit) => Promise<Response>;

/** Fetch the artifact listing. Throws {@link ArtifactsError} with the HTTP status on failure. */
export async function listArtifacts(
	params: ArtifactListParams = {},
	fetchFn: ArtifactsFetch = apiFetch
): Promise<ArtifactListResponse<ArtifactRow>> {
	const qs = buildArtifactsQuery(params);
	const url = qs ? `/Api/Artifacts?${qs}` : '/Api/Artifacts';
	const res = await fetchFn(url);
	if (!res.ok) {
		const message = await parseErrorMessage(res);
		throw new ArtifactsError(res.status, message);
	}
	return (await res.json()) as ArtifactListResponse<ArtifactRow>;
}

/** Fetch the grants minted against one artifact, newest first. */
export async function listArtifactGrants(
	artifactId: string,
	fetchFn: ArtifactsFetch = apiFetch
): Promise<ArtifactListResponse<ArtifactGrantRow>> {
	const res = await fetchFn(`/Api/Artifacts/${encodeURIComponent(artifactId)}/grants`);
	if (!res.ok) {
		const message = await parseErrorMessage(res);
		throw new ArtifactsError(res.status, message);
	}
	return (await res.json()) as ArtifactListResponse<ArtifactGrantRow>;
}

/** Fetch the `artifact_references` rows for one artifact, with projection labels. */
export async function listArtifactReferences(
	artifactId: string,
	fetchFn: ArtifactsFetch = apiFetch
): Promise<ArtifactListResponse<ArtifactReferenceRow>> {
	const res = await fetchFn(`/Api/Artifacts/${encodeURIComponent(artifactId)}/references`);
	if (!res.ok) {
		const message = await parseErrorMessage(res);
		throw new ArtifactsError(res.status, message);
	}
	return (await res.json()) as ArtifactListResponse<ArtifactReferenceRow>;
}

/**
 * Revoke one grant via the shared grant route (`DELETE
 * /Api/core/artifacts/grants/:gid`). The backend accepts the operator
 * `revoke *.*` action; a `403` surfaces so the page can render the
 * permission message distinctly.
 */
export async function revokeArtifactGrant(
	grantId: string,
	fetchFn: ArtifactsFetch = apiFetch
): Promise<void> {
	const res = await fetchFn(`/Api/core/artifacts/grants/${encodeURIComponent(grantId)}`, {
		method: 'DELETE'
	});
	if (!res.ok) {
		const message = await parseErrorMessage(res);
		throw new ArtifactsError(res.status, message);
	}
}

/**
 * Force delete one artifact via the admin surface (`DELETE
 * /Api/Artifacts/:id`). A security deletion: the backend destroys the row,
 * the bytes, and every child row, and writes the `iam.ArtifactEvent` audit
 * record with the operator's reason. The `X-Requested-With` header is the
 * CSRF discipline of every destructive route. A `403` surfaces so the page
 * can render the permission message distinctly.
 */
export async function purgeArtifact(
	artifactId: string,
	reason: string,
	fetchFn: ArtifactsFetch = apiFetch
): Promise<void> {
	const res = await fetchFn(`/Api/Artifacts/${encodeURIComponent(artifactId)}`, {
		method: 'DELETE',
		headers: {
			'X-Requested-With': 'XMLHttpRequest',
			'Content-Type': 'application/json'
		},
		body: JSON.stringify({ reason })
	});
	if (!res.ok) {
		const message = await parseErrorMessage(res);
		throw new ArtifactsError(res.status, message);
	}
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

/** Human-readable byte size (`512 B`, `1.2 MB`) — data formatting, not UI copy. */
export function formatArtifactSize(bytes: number): string {
	if (bytes < 1024) return `${bytes} B`;
	const units = ['KB', 'MB', 'GB', 'TB'];
	let value = bytes;
	let unit = -1;
	do {
		value /= 1024;
		unit += 1;
	} while (value >= 1024 && unit < units.length - 1);
	return `${value >= 100 ? Math.round(value) : value.toFixed(1)} ${units[unit]}`;
}
