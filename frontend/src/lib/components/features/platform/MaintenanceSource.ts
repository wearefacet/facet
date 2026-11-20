// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { apiFetch } from '$lib/session.svelte.js';

/**
 * Doctype-maintenance data plumbing — the operator surface over the
 * maintenance routes of `core.DocType`: status counts, re-project /
 * migrate-ahead job enqueue, and the job list.
 *
 * Pure adapter logic in the same shape as `IndexesSource.ts`: query
 * building, response parsing, and error mapping live here so the panel
 * component and the page stay pure renderers. The fetcher is injectable
 * so pure-logic tests can stub responses without touching the session
 * layer.
 */

/** Maintenance counters for one doctype (`GET .../maintenance_status`). */
export interface MaintenanceStatus {
	doctype_id: string;
	current_version: number;
	/** Documents whose version sits below the doctype's current version. */
	ahead_count: number;
	/** Documents blocked by a failed migration attempt. */
	blocked_count: number;
}

/** Kind of a maintenance job row. */
export type MaintenanceJobKind = 'doctype_reproject' | 'doctype_migrate_ahead';

/** Lifecycle status of a maintenance job. */
export type MaintenanceJobStatus = 'pending' | 'running' | 'succeeded' | 'failed';

/** One row of the maintenance job list (`GET .../maintenance_jobs`). */
export interface MaintenanceJobRow {
	id: string;
	kind: MaintenanceJobKind;
	status: MaintenanceJobStatus;
	attempts: number;
	max_attempts: number;
	last_error: string | null;
	/** Run stats written when the job succeeded — see {@link JobStats}. */
	result: Record<string, unknown> | null;
	account_id: string | null;
	role_id: string | null;
	created_at: string;
	updated_at: string;
}

/** Response of `GET .../maintenance_jobs` — the platform `{ data, meta }` shape. */
export interface MaintenanceJobsResponse {
	data: MaintenanceJobRow[];
	meta: { count: number; more: boolean; page: number };
}

/** Params for the job list. */
export interface MaintenanceJobsParams {
	page?: number;
	items?: number;
}

/** Response of the enqueue routes (`POST .../reproject`, `POST .../migrate_ahead`). */
export interface EnqueueJobResult {
	job_id: string;
	status_url: string;
}

/**
 * The enqueue actions the maintenance surface offers — the UI-facing key
 * that maps to one backend route (`reproject` → `POST .../reproject`,
 * `migrate` → `POST .../migrate_ahead`).
 */
export type MaintenanceActionKind = 'reproject' | 'migrate';

/** Typed error carrying the HTTP status so the page can render 403 distinctly. */
export class MaintenanceError extends Error {
	status: number;

	constructor(status: number, message: string) {
		super(message);
		this.name = 'MaintenanceError';
		this.status = status;
	}
}

/** apiFetch-compatible signature: string URL input, optional init. */
export type MaintenanceFetch = (input: string, init?: RequestInit) => Promise<Response>;

/** Build the query string for `GET .../maintenance_jobs` from list params. */
export function buildJobsQuery(params: MaintenanceJobsParams): string {
	const query = new URLSearchParams();
	if (params?.page) query.set('page', String(params.page));
	if (params?.items) query.set('items', String(params.items));
	return query.toString();
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

async function raise(res: Response): Promise<never> {
	throw new MaintenanceError(res.status, await parseErrorMessage(res));
}

/**
 * Fetch the maintenance counters for one doctype. Throws
 * {@link MaintenanceError} with the HTTP status on failure — `403` when the
 * role lacks wildcard read, `404` for an unknown doctype.
 */
export async function fetchMaintenanceStatus(
	doctypeId: string,
	fetchFn: MaintenanceFetch = apiFetch
): Promise<MaintenanceStatus> {
	const res = await fetchFn(`/Api/core/DocType/${doctypeId}/maintenance_status`);
	if (!res.ok) await raise(res);
	return (await res.json()) as MaintenanceStatus;
}

/**
 * Enqueue a re-project job (recomputes the derived columns of every
 * document of the doctype). Answers `202` with the job handle; `409` when
 * an identical job is already pending or running (the message names the
 * kind), `422` in preview mode.
 */
export async function enqueueReproject(
	doctypeId: string,
	fetchFn: MaintenanceFetch = apiFetch
): Promise<EnqueueJobResult> {
	const res = await fetchFn(`/Api/core/DocType/${doctypeId}/reproject`, {
		method: 'POST',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify({})
	});
	if (!res.ok) await raise(res);
	return (await res.json()) as EnqueueJobResult;
}

/**
 * Enqueue an ahead-migration job (migrates documents sitting below the
 * doctype's current version). Same `202`/`409`/`404`/`422` contract as
 * {@link enqueueReproject}.
 */
export async function enqueueMigrateAhead(
	doctypeId: string,
	fetchFn: MaintenanceFetch = apiFetch
): Promise<EnqueueJobResult> {
	const res = await fetchFn(`/Api/core/DocType/${doctypeId}/migrate_ahead`, {
		method: 'POST',
		headers: { 'Content-Type': 'application/json' },
		body: JSON.stringify({})
	});
	if (!res.ok) await raise(res);
	return (await res.json()) as EnqueueJobResult;
}

/**
 * List the maintenance jobs of one doctype, newest page first per the
 * platform pagination grammar.
 */
export async function listMaintenanceJobs(
	doctypeId: string,
	params: MaintenanceJobsParams = {},
	fetchFn: MaintenanceFetch = apiFetch
): Promise<MaintenanceJobsResponse> {
	const qs = buildJobsQuery(params);
	const base = `/Api/core/DocType/${doctypeId}/maintenance_jobs`;
	const url = qs ? `${base}?${qs}` : base;
	const res = await fetchFn(url);
	if (!res.ok) await raise(res);
	return (await res.json()) as MaintenanceJobsResponse;
}

/**
 * Run stats of a succeeded job, normalized out of `row.result`:
 * reproject carries `processed`, migrate_ahead carries `migrated`; both
 * carry `superseded`/`skipped`/`failed` and optionally `total`, `batches`
 * and the ids of the documents that failed. `null` when the row has no
 * usable result payload (pending, running, or a legacy failed row).
 */
export interface JobStats {
	processed: number | null;
	migrated: number | null;
	superseded: number | null;
	skipped: number | null;
	failed: number | null;
	total: number | null;
	batches: number | null;
	failedIds: string[];
}

function asNumber(value: unknown): number | null {
	return typeof value === 'number' && Number.isFinite(value) ? value : null;
}

/** Extract the display stats from a job row's `result` payload. */
export function extractJobStats(row: MaintenanceJobRow): JobStats | null {
	const result = row.result;
	if (typeof result !== 'object' || result === null) return null;
	const failedIds = Array.isArray(result['failed_ids'])
		? result['failed_ids'].filter((v): v is string => typeof v === 'string')
		: [];
	const stats: JobStats = {
		processed: asNumber(result['processed']),
		migrated: asNumber(result['migrated']),
		superseded: asNumber(result['superseded']),
		skipped: asNumber(result['skipped']),
		failed: asNumber(result['failed']),
		total: asNumber(result['total']),
		batches: asNumber(result['batches']),
		failedIds
	};
	const meaningful =
		stats.processed ?? stats.migrated ?? stats.superseded ?? stats.skipped ?? stats.failed;
	if (meaningful === null && stats.failedIds.length === 0) return null;
	return stats;
}
