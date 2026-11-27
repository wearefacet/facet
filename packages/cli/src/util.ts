// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { generateKeyPairSync, randomBytes } from 'node:crypto';

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

/**
 * A base64 secret of 32 random bytes — the shape every Facet secret expects
 * (`POSTGRES_PASSWORD`, `FACET_SECRETS_MASTER_KEY`, `FACET_ARTIFACT_GRANT_SECRET`).
 */
export function generateSecret(): string {
	return randomBytes(32).toString('base64');
}

/**
 * A P-256 private key in PEM form — the `JWT_SIGNING_KEY` the backend reads
 * from the environment. Single-line PEM with `\n` escapes, so it rides in a
 * `.env` value unquoted-newline style the compose loader expands.
 */
export function generateJwtSigningKey(): string {
	const { privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
	const pem = privateKey.export({ type: 'sec1', format: 'pem' }).toString();
	return pem.trimEnd();
}
