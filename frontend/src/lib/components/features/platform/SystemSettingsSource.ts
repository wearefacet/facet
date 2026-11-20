// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { apiFetch } from '$lib/session.svelte.js';

/**
 * System-settings data plumbing — `GET /Api/SystemSettings` (effective
 * values + pinned paths), the sparse document PATCH, and the out-of-band
 * secret staging for the two credential fields.
 *
 * Pure adapter logic in the same shape as `ArtifactsSource.ts`: the fetcher
 * is injectable so stories can stub responses without touching the session
 * layer. Saves go through the standard document update route
 * (`PATCH /Api/core/SystemSettings/settings`) — RBAC, the write-time
 * validation split, secret adoption, and the event fanout all apply
 * server-side; see `doc/backend/system-settings.md`.
 */

/** The GET response: effective non-secret values keyed by dot-path, plus the paths the document pins. */
export interface SystemSettingsResponse {
	values: Record<string, unknown>;
	pinned: string[];
}

/** Typed error carrying the HTTP status so the page can render `403` distinctly. */
export class SystemSettingsError extends Error {
	status: number;
	/** Parsed `422` field details (empty unless the write-time gate rejected the save). */
	fieldErrors: SettingsFieldError[];

	constructor(status: number, message: string, fieldErrors: SettingsFieldError[] = []) {
		super(message);
		this.name = 'SystemSettingsError';
		this.status = status;
		this.fieldErrors = fieldErrors;
	}
}

/** apiFetch-compatible signature: string URL input, optional init. */
export type SystemSettingsFetch = (input: string, init?: RequestInit) => Promise<Response>;

/** Fetch the effective settings snapshot. Throws {@link SystemSettingsError} with the HTTP status on failure. */
export async function getSystemSettings(
	fetchFn: SystemSettingsFetch = apiFetch
): Promise<SystemSettingsResponse> {
	const res = await fetchFn('/Api/SystemSettings');
	if (!res.ok) {
		const message = await parseErrorMessage(res);
		throw new SystemSettingsError(res.status, message);
	}
	return (await res.json()) as SystemSettingsResponse;
}

/**
 * Stage one secret plaintext out-of-band (`POST /Api/secrets/stage`) and
 * return the single-use handle. The page puts the handle into the sparse
 * PATCH body; the write pipeline adopts it into the secret store and
 * substitutes the marker. The plaintext never enters a document body.
 */
export async function stageSystemSecret(
	fieldPath: string,
	value: string,
	fetchFn: SystemSettingsFetch = apiFetch
): Promise<string> {
	const res = await fetchFn('/Api/secrets/stage', {
		method: 'POST',
		headers: {
			'Content-Type': 'application/json',
			'X-Requested-With': 'XMLHttpRequest'
		},
		body: JSON.stringify({
			domain: 'core',
			doctype: 'SystemSettings',
			field_path: fieldPath,
			doc_id: 'settings',
			value
		})
	});
	if (!res.ok) {
		const message = await parseErrorMessage(res);
		throw new SystemSettingsError(res.status, message);
	}
	const body = (await res.json()) as { handle: string };
	return body.handle;
}

/**
 * Sparse save through the standard document update route. `patch` carries
 * only the fields the admin edited, plus explicit `null` for the fields the
 * admin reset — the backend deep-merges it over the document content, so
 * untouched fields (pinned or not) keep their state. Returns the parsed
 * `422` field details when the write-time gate rejects the save, so the
 * form can attribute errors to paths.
 */
export async function saveSystemSettings(
	patch: Record<string, unknown>,
	fetchFn: SystemSettingsFetch = apiFetch
): Promise<void> {
	const res = await fetchFn('/Api/core/SystemSettings/settings', {
		method: 'PATCH',
		headers: {
			'Content-Type': 'application/json',
			'X-Requested-With': 'XMLHttpRequest'
		},
		body: JSON.stringify(patch)
	});
	if (!res.ok) {
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
		throw new SystemSettingsError(
			res.status,
			message,
			res.status === 422 ? parseFieldErrors(body) : []
		);
	}
}

/**
 * Sends one test email through the saved mail connector
 * (`POST /Api/SystemSettings/mail/test`). The probe rides the effective
 * document-over-file settings — the same path a password reset takes — so
 * pending form edits do not participate: save first, then test.
 *
 * Blocking by design: the request waits for the transport and returns the
 * resolved adapter on success. A `422` means Facet refused before the wire
 * (the connector is off, or the address is malformed); a `502` carries the
 * transport's own message — the diagnostic the operator asked for.
 */
export async function sendTestMail(
	to: string,
	fetchFn: SystemSettingsFetch = apiFetch
): Promise<TestMailResult> {
	const res = await fetchFn('/Api/SystemSettings/mail/test', {
		method: 'POST',
		headers: {
			'Content-Type': 'application/json',
			'X-Requested-With': 'XMLHttpRequest'
		},
		body: JSON.stringify({ to })
	});
	if (!res.ok) {
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
		throw new SystemSettingsError(
			res.status,
			message,
			res.status === 422 ? parseFieldErrors(body) : []
		);
	}
	return (await res.json()) as TestMailResult;
}

/**
 * Sends one minimal completion through the saved assistant settings
 * (`POST /Api/SystemSettings/assistant/test`). The probe rides the effective
 * document-over-file settings — the same path a chat turn takes — so pending
 * form edits do not participate: save first, then test.
 *
 * Blocking by design: the request waits for the provider and returns the
 * resolved model and its reply on success. A `422` means Facet refused
 * before the wire (no API key resolves — the unconfigured posture); a `502`
 * carries the transport's own message — the diagnostic the operator asked
 * for. No request body: the saved settings are the input.
 */
export async function testAssistant(
	fetchFn: SystemSettingsFetch = apiFetch
): Promise<TestAssistantResult> {
	const res = await fetchFn('/Api/SystemSettings/assistant/test', {
		method: 'POST',
		headers: {
			'Content-Type': 'application/json',
			'X-Requested-With': 'XMLHttpRequest'
		}
	});
	if (!res.ok) {
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
		throw new SystemSettingsError(
			res.status,
			message,
			res.status === 422 ? parseFieldErrors(body) : []
		);
	}
	return (await res.json()) as TestAssistantResult;
}

/** The test-mail success body: which transport carried the probe, and to whom. */
export interface TestMailResult {
	adapter: string;
	from_address: string;
	to: string;
}

/** The test-assistant success body: which model answered, at which endpoint, and its reply (when the shape allowed). */
export interface TestAssistantResult {
	model: string;
	endpoint: string;
	reply: string | null;
}

/** One structured `422` detail as the backend's validation errors serialize. */
export interface SettingsFieldError {
	field: string | null;
	message: string;
	code: string | null;
}

/** Parses a `422` body's `details` array into structured field errors. */
export function parseFieldErrors(body: unknown): SettingsFieldError[] {
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

/** Extract a backend error message, falling back to a status-based default. */
async function parseErrorMessage(res: Response): Promise<string> {
	try {
		const body = (await res.json()) as { error?: string; message?: string };
		return body.error ?? body.message ?? res.statusText;
	} catch {
		return res.statusText || 'Request failed';
	}
}
