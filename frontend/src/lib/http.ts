// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Shared helper for failed JSON API responses. Every thin API client built
 * this same error shape locally; it now lives once, next to nothing else,
 * so the message contract (`body.error` first, else fallback + status) has
 * one home.
 */

/** Build an `Error` from a failed JSON response: body `error` first, else `${fallback} (${status})`. */
export async function apiErrorMessage(res: Response, fallback: string): Promise<Error> {
	const body = (await res.json().catch(() => ({}))) as { error?: string };
	return new Error(body.error ?? `${fallback} (${res.status})`);
}
