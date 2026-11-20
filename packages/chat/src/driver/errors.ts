// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Error type and response-body helper for the assistant HTTP layer.
 *
 * Dependency-free by design — no paraglide, no `apiFetch` — so any driver,
 * mock, or test can import this module without pulling in the app runtime.
 */

/**
 * Error thrown when an assistant API call returns a non-2xx status. Carries
 * the status code so callers can distinguish 404 (conversation not found)
 * from 429 (usage limit) / 500 (server error), and the backend's `error`
 * text when the response body carried one.
 */
export class HttpAssistantError extends Error {
	constructor(
		readonly status: number,
		readonly statusText: string,
		message?: string
	) {
		super(message ?? `${status} ${statusText}`);
		this.name = 'HttpAssistantError';
	}
}

/**
 * Reads the `{error: "…"}` payload of a failed response. Returns the text
 * when it is a non-empty string; returns `undefined` for a non-JSON body, a
 * missing or empty `error` field, or any read failure — callers then fall
 * back to the status text.
 */
export async function readErrorMessage(res: Response): Promise<string | undefined> {
	try {
		const body = (await res.json()) as { error?: unknown };
		const message = body?.error;
		return typeof message === 'string' && message.length > 0 ? message : undefined;
	} catch {
		return undefined;
	}
}
