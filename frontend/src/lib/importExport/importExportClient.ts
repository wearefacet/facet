// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Import/export API client — the thin wrapper over the concern's four
 * machine routes (`POST .../export`, `POST .../import`, `GET .../import_export/:id`,
 * `GET .../import_export/:id/download`).
 *
 * Pure logic, no framework imports: every function takes an injectable
 * `fetchImpl`, so the status-poll engine and the response shapes are
 * testable in Vitest's node project without a browser or module state.
 * Components pass `apiFetch` (which carries token refresh / 401 recovery).
 */

import * as m from '$lib/paraglide/messages';

export type ImportFormat = 'csv' | 'json';

/** The `202` enqueue-mode body, normalised. */
export interface EnqueueResult {
	jobId: string;
	statusUrl: string;
	/** Import only — the synchronously parsed row count. */
	rowCount?: number;
}

/** The current table view state a view export renders. The component seam
 * carries it without the timezone; the export call site resolves the zone
 * through `displayTimezone()` — the client stays framework-free. */
export interface ViewExportState {
	/** Column keys to export, in display order. */
	columns: string[];
	/** The compacted filter map the datasource receives. */
	filters: Record<string, unknown>;
	/** Sort grammar entries (e.g. `['-created_at']`); empty keeps id order. */
	sort: string[];
	/** IANA zone for the CSV timestamp cells. */
	timezone: string;
}

/** The component-seam shape: the view state without the timezone, which the
 * `ExportMenu` call site resolves. `null` on the seam hides the view item. */
export type ViewExportItem = Omit<ViewExportState, 'timezone'>;

/** The job status body, normalised. */
export interface JobStatus {
	id: string;
	status: 'pending' | 'running' | 'succeeded' | 'failed';
	/** Export success: artifact coordinates. Import success: the upsert report. */
	result?: Record<string, unknown> | null;
	/** Crash-class failure message. */
	error?: string | null;
}

/** Import success report (`result` of a succeeded import job). */
export interface ImportReport {
	row_count: number;
	created: number;
	updated: number;
	skipped: number;
}

/** The failing row of a failed import (`result` of a failed job). */
export interface ImportRowError {
	row: number;
	field?: string | null;
	message: string;
}

export type PollOutcome = { mode: 'resolved'; status: JobStatus } | { mode: 'timeout' };

export type FetchImpl = (input: string, init?: RequestInit) => Promise<Response>;

/** An API error with the backend's message and HTTP status. */
export class ImportError extends Error {
	status: number;

	constructor(status: number, message: string) {
		super(message);
		this.name = 'ImportError';
		this.status = status;
	}
}

async function parseError(response: Response): Promise<ImportError> {
	let message = m.impex_request_failed({ status: response.status });
	try {
		const body = await response.json();
		if (body && typeof body.error === 'string') message = body.error;
	} catch {
		/* non-JSON body — keep the default message */
	}
	return new ImportError(response.status, message);
}

// ── Enqueue ────────────────────────────────────────────────────────────

/** Enqueues one export job. The import/export POSTs follow the CSRF rule —
 * the caller supplies the `fetchImpl` (apiFetch adds the credentials), and
 * this sets the `X-Requested-With` header the backend demands. */
export async function enqueueExport(
	fetchImpl: FetchImpl,
	domain: string,
	doctype: string,
	format: ImportFormat
): Promise<EnqueueResult> {
	const response = await fetchImpl(`/Api/${domain}/${doctype}/export?format=${format}`, {
		method: 'POST',
		headers: { 'X-Requested-With': 'XMLHttpRequest' }
	});
	if (!response.ok) throw await parseError(response);
	const body = await response.json();
	return { jobId: body.job_id, statusUrl: body.status_url };
}

/** Enqueues one view export: the table's current columns, sort, and
 * filters ride a JSON body to the `export_view` route. Same shape as
 * `enqueueExport`, so the poll and download plumbing is reused unchanged. */
export async function enqueueViewExport(
	fetchImpl: FetchImpl,
	domain: string,
	doctype: string,
	view: ViewExportState
): Promise<EnqueueResult> {
	const response = await fetchImpl(`/Api/${domain}/${doctype}/export_view`, {
		method: 'POST',
		headers: {
			'Content-Type': 'application/json',
			'X-Requested-With': 'XMLHttpRequest'
		},
		body: JSON.stringify({
			columns: view.columns,
			sort: view.sort,
			filters: view.filters,
			timezone: view.timezone
		})
	});
	if (!response.ok) throw await parseError(response);
	const body = await response.json();
	return { jobId: body.job_id, statusUrl: body.status_url };
}

/** Uploads one import file. `body` is the raw CSV text or JSON string; the
 * `Content-Type` carries the format decision to the backend's detector. */
export async function enqueueImport(
	fetchImpl: FetchImpl,
	domain: string,
	doctype: string,
	body: string,
	format: ImportFormat
): Promise<EnqueueResult> {
	const response = await fetchImpl(`/Api/${domain}/${doctype}/import`, {
		method: 'POST',
		headers: {
			'Content-Type': format === 'csv' ? 'text/csv' : 'application/json',
			'X-Requested-With': 'XMLHttpRequest'
		},
		body
	});
	if (!response.ok) throw await parseError(response);
	const parsed = await response.json();
	return {
		jobId: parsed.job_id,
		statusUrl: parsed.status_url,
		rowCount: typeof parsed.row_count === 'number' ? parsed.row_count : undefined
	};
}

// ── Status + wait ──────────────────────────────────────────────────────

export async function fetchJobStatus(
	fetchImpl: FetchImpl,
	domain: string,
	doctype: string,
	jobId: string
): Promise<JobStatus> {
	const response = await fetchImpl(`/Api/${domain}/${doctype}/import_export/${jobId}`);
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
	domain: string,
	doctype: string,
	jobId: string,
	opts?: { pollMs?: number; timeoutMs?: number; delay?: (ms: number) => Promise<void> }
): Promise<PollOutcome> {
	const pollMs = opts?.pollMs ?? 500;
	const timeoutMs = opts?.timeoutMs ?? 30_000;
	const delay = opts?.delay ?? ((ms: number) => new Promise<void>((r) => setTimeout(r, ms)));
	const deadline = Date.now() + timeoutMs;

	while (true) {
		const status = await fetchJobStatus(fetchImpl, domain, doctype, jobId);
		if (TERMINAL.has(status.status)) return { mode: 'resolved', status };
		if (Date.now() >= deadline) return { mode: 'timeout' };
		await delay(pollMs);
	}
}

/** The terminal-status shape the toolbar and the dialog branch on. */
export function importReportOf(
	result: Record<string, unknown> | null | undefined
): ImportReport | null {
	if (
		result &&
		typeof result === 'object' &&
		typeof (result as unknown as ImportReport).row_count === 'number'
	) {
		return result as unknown as ImportReport;
	}
	return null;
}

export function importRowErrorOf(
	result: Record<string, unknown> | null | undefined
): ImportRowError | null {
	if (
		result &&
		typeof result === 'object' &&
		typeof (result as unknown as ImportRowError).row === 'number' &&
		typeof (result as unknown as ImportRowError).message === 'string'
	) {
		return result as unknown as ImportRowError;
	}
	return null;
}

export function downloadUrl(domain: string, doctype: string, jobId: string): string {
	return `/Api/${domain}/${doctype}/import_export/${jobId}/download`;
}

// ── File helpers (client-side preview only — never authoritative) ──────

/** Detects the upload format from MIME type, then the file extension. */
export function detectFormat(file: File): ImportFormat | null {
	if (file.type === 'text/csv') return 'csv';
	if (file.type === 'application/json') return 'json';
	const name = file.name.toLowerCase();
	if (name.endsWith('.csv')) return 'csv';
	if (name.endsWith('.json')) return 'json';
	return null;
}

/**
 * Parses the first data row/columns out of an upload for the dialog's
 * header preview. Shape-only and tolerant: a file the backend rejects still
 * previews what was readable — the authoritative parse happens server-side
 * at enqueue.
 */
export function previewHeader(
	text: string,
	format: ImportFormat
): { columns: string[]; rowCount: number | null } {
	if (format === 'json') {
		try {
			const parsed: unknown = JSON.parse(text);
			if (Array.isArray(parsed)) {
				const first = parsed[0];
				const columns =
					first && typeof first === 'object' ? Object.keys(first as Record<string, unknown>) : [];
				return { columns, rowCount: parsed.length };
			}
		} catch {
			/* fall through to the empty preview */
		}
		return { columns: [], rowCount: null };
	}

	const lines = text.split(/\r\n|\n|\r/).filter((l) => l.trim().length > 0);
	if (lines.length === 0) return { columns: [], rowCount: null };
	return { columns: splitCsvLine(lines[0]), rowCount: lines.length - 1 };
}

/** One CSV line → cells. Handles quoted commas and doubled quotes; newlines
 * inside quotes are out of scope for the preview (the backend parses). */
function splitCsvLine(line: string): string[] {
	const cells: string[] = [];
	let current = '';
	let inQuotes = false;
	for (let i = 0; i < line.length; i++) {
		const ch = line[i];
		if (inQuotes) {
			if (ch === '"') {
				if (line[i + 1] === '"') {
					current += '"';
					i++;
				} else {
					inQuotes = false;
				}
			} else {
				current += ch;
			}
		} else if (ch === '"') {
			inQuotes = true;
		} else if (ch === ',') {
			cells.push(current);
			current = '';
		} else {
			current += ch;
		}
	}
	cells.push(current);
	return cells;
}
