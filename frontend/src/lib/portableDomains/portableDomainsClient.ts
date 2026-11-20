// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Portable-domain API client — the thin wrapper over the concern's four
 * machine routes (`POST /Api/core/Domain/:id/export`, `POST /Api/core/Domain/import`,
 * `GET /Api/core/Domain/import_export/:id`, `GET /Api/core/Domain/import_export/:id/download`).
 *
 * Pure logic, no framework imports: every function takes an injectable
 * `fetchImpl`, so the status-poll engine and the response shapes are
 * testable in Vitest's node project without a browser or module state.
 * Components pass `apiFetch` (which carries token refresh / 401 recovery).
 *
 * Over HTTP a bundle is definition-only — an archive carrying a documents
 * section refuses at enqueue — and an export captures a published domain
 * only (a draft refuses with `422`).
 */

import * as m from '$lib/paraglide/messages';

/** The `202` enqueue-mode body, normalised. */
export interface EnqueueResult {
	jobId: string;
	statusUrl: string;
	/** Import only — the domain the bundle applies to (`into` || `source_domain`). */
	targetDomain?: string;
}

/** The job status body, normalised. */
export interface JobStatus {
	id: string;
	status: 'pending' | 'running' | 'succeeded' | 'failed';
	/** Export success: artifact coordinates. Import success: the counters report. */
	result?: Record<string, unknown> | null;
	/** The expected-failure message (the version gate, a `409` conflict, …). */
	error?: string | null;
}

/** Export success report (`result` of a succeeded export job). */
export interface DomainExportResult {
	artifact_id: string;
	doctype_count: number;
	document_view_count: number;
	collection_view_count: number;
	format: string;
}

/** Import success report (`result` of a succeeded import job). */
export interface DomainImportReport {
	domain: string;
	created: number;
	doctypes_created: number;
	doctypes_updated: number;
	doctypes_unchanged: number;
	document_views_created: number;
	document_views_updated: number;
	document_views_deleted: number;
	collection_views_created: number;
	collection_views_updated: number;
	documents_created: number;
}

export type PollOutcome = { mode: 'resolved'; status: JobStatus } | { mode: 'timeout' };

export type FetchImpl = (input: string, init?: RequestInit) => Promise<Response>;

/** An API error with the backend's message and HTTP status. */
export class PortableDomainError extends Error {
	status: number;

	constructor(status: number, message: string) {
		super(message);
		this.name = 'PortableDomainError';
		this.status = status;
	}
}

async function parseError(response: Response): Promise<PortableDomainError> {
	let message = m.impex_request_failed({ status: response.status });
	try {
		const body = await response.json();
		if (body && typeof body.error === 'string') message = body.error;
	} catch {
		/* non-JSON body — keep the default message */
	}
	return new PortableDomainError(response.status, message);
}

// ── Enqueue ────────────────────────────────────────────────────────────

/** Enqueues one export job for a published domain. The POST follows the
 * CSRF rule — the caller supplies the `fetchImpl` (apiFetch adds the
 * credentials), and this sets the `X-Requested-With` header the backend
 * demands. */
export async function enqueueDomainExport(
	fetchImpl: FetchImpl,
	domain: string
): Promise<EnqueueResult> {
	const response = await fetchImpl(`/Api/core/Domain/${encodeURIComponent(domain)}/export`, {
		method: 'POST',
		headers: { 'X-Requested-With': 'XMLHttpRequest' }
	});
	if (!response.ok) throw await parseError(response);
	const body = await response.json();
	return { jobId: body.job_id, statusUrl: body.status_url };
}

/** Uploads one bundle archive (zip or tar.gz). `into` renames the target
 * domain; `merge` selects the upsert branch against an existing target. */
export async function enqueueDomainImport(
	fetchImpl: FetchImpl,
	bundle: File,
	opts?: { into?: string; merge?: boolean }
): Promise<EnqueueResult> {
	const params = new URLSearchParams();
	if (opts?.into) params.set('into', opts.into);
	if (opts?.merge) params.set('merge', 'true');
	const qs = params.toString();
	const response = await fetchImpl(`/Api/core/Domain/import${qs ? `?${qs}` : ''}`, {
		method: 'POST',
		headers: {
			// The route sniffs the archive's magic bytes — the media type is
			// not consulted, so the upload goes out as opaque bytes.
			'Content-Type': 'application/octet-stream',
			'X-Requested-With': 'XMLHttpRequest'
		},
		body: bundle
	});
	if (!response.ok) throw await parseError(response);
	const parsed = await response.json();
	return {
		jobId: parsed.job_id,
		statusUrl: parsed.status_url,
		targetDomain: typeof parsed.target_domain === 'string' ? parsed.target_domain : undefined
	};
}

// ── Status + wait ──────────────────────────────────────────────────────

export async function fetchJobStatus(fetchImpl: FetchImpl, jobId: string): Promise<JobStatus> {
	const response = await fetchImpl(`/Api/core/Domain/import_export/${jobId}`);
	if (!response.ok) throw await parseError(response);
	const body = await response.json();
	return {
		id: body.id,
		status: body.status,
		result: body.result ?? null,
		error: body.error ?? null
	};
}

const TERMINAL = new Set(['succeeded', 'failed']);

/**
 * Polls the status route until the job is terminal or the deadline passes.
 * Resolution timing is injectable through `opts.delay` (defaults to a real
 * `setTimeout`) so tests drive the clock synchronously.
 */
export async function pollJob(
	fetchImpl: FetchImpl,
	jobId: string,
	opts?: { pollMs?: number; timeoutMs?: number; delay?: (ms: number) => Promise<void> }
): Promise<PollOutcome> {
	const pollMs = opts?.pollMs ?? 500;
	const timeoutMs = opts?.timeoutMs ?? 30_000;
	const delay = opts?.delay ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
	const deadline = Date.now() + timeoutMs;

	while (true) {
		const status = await fetchJobStatus(fetchImpl, jobId);
		if (TERMINAL.has(status.status)) return { mode: 'resolved', status };
		if (Date.now() >= deadline) return { mode: 'timeout' };
		await delay(pollMs);
	}
}

// ── Terminal-result normalisers ────────────────────────────────────────

/** The terminal-status shape the toast flow branches on. */
export function exportResultOf(
	result: Record<string, unknown> | null | undefined
): DomainExportResult | null {
	if (
		result &&
		typeof result === 'object' &&
		typeof (result as unknown as DomainExportResult).doctype_count === 'number'
	) {
		return result as unknown as DomainExportResult;
	}
	return null;
}

/** The terminal-status shape the dialog branches on. */
export function importReportOf(
	result: Record<string, unknown> | null | undefined
): DomainImportReport | null {
	if (
		result &&
		typeof result === 'object' &&
		typeof (result as unknown as DomainImportReport).doctypes_created === 'number'
	) {
		return result as unknown as DomainImportReport;
	}
	return null;
}

export function domainDownloadUrl(jobId: string): string {
	return `/Api/core/Domain/import_export/${jobId}/download`;
}

// ── File helper (client-side guard only — never authoritative) ────────

/** Detects the bundle archive extensions the import route accepts. The
 * backend sniffs the magic bytes; this check only guards the obvious
 * wrong file before an upload leaves the browser. */
export function isBundleFile(file: File): boolean {
	const name = file.name.toLowerCase();
	return name.endsWith('.zip') || name.endsWith('.tar.gz') || name.endsWith('.tgz');
}
