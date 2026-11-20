// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/** Renders any thrown value as a readable message. */
export function errorMessage(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}

/**
 * Strips the `{domain}.{Doctype}.` prefix from a stored reference token so
 * it compares equal to the bare `meta.id` the list routes return. Stored
 * reference values are qualified; document ids elsewhere in the API are
 * bare.
 */
export function bareDocId(reference: string): string {
	const parts = reference.split('.');
	return parts.length > 2 ? (parts[parts.length - 1] ?? reference) : reference;
}
