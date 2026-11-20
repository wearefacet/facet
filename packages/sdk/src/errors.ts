// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/** One structured validation error from a `422` body. */
export interface ValidationError {
	/** Dot-separated field path. Absent for non-field errors (script, RBAC, schema). */
	field?: string | null;
	/** Human-readable message. */
	message: string;
	/** Machine-readable category, e.g. `required` or `invalid_type`. */
	code?: string | null;
	/** Interpolations behind a templated `code`. */
	params?: Record<string, string> | null;
}

/** Raised for any failed HTTP exchange with a Facet instance. */
export class ApiError extends Error {
	/** HTTP status, or `0` when no exchange happened. */
	readonly status: number;
	/** Structured detail items from the server's `details` array. */
	readonly details: ValidationError[];
	/** Flat extra fields from the error body, such as tombstone data on a `410`. */
	readonly meta: Record<string, unknown>;

	constructor(
		message: string,
		status: number,
		details: ValidationError[] = [],
		meta: Record<string, unknown> = {}
	) {
		super(message);
		this.name = 'ApiError';
		this.status = status;
		this.details = details;
		this.meta = meta;
	}
}

/** Raised when no credential is available, or a token refresh failed. The caller must sign in again. */
export class AuthError extends ApiError {
	constructor(message: string) {
		super(message, 0);
		this.name = 'AuthError';
	}
}

/** Raised for a `404`. The backend denies with `404`, so it never discloses existence. */
export class NotFoundError extends ApiError {
	constructor(
		message: string,
		details: ValidationError[] = [],
		meta: Record<string, unknown> = {}
	) {
		super(message, 404, details, meta);
		this.name = 'NotFoundError';
	}
}

/** Raised for a `410`. The document existed and is soft-deleted. */
export class DeletedError extends ApiError {
	/** Human label kept on the tombstone. */
	readonly displayName: string | null;
	/** Deletion timestamp kept on the tombstone, RFC-3339. */
	readonly deletedAt: string | null;

	constructor(message: string, meta: Record<string, unknown> = {}) {
		super(message, 410, [], meta);
		this.name = 'DeletedError';
		this.displayName = readMetaString(meta, 'display_name');
		this.deletedAt = readMetaString(meta, 'deleted_at');
	}
}

/** Raised when `fetch` threw. The request never reached the server. */
export class NetworkError extends ApiError {
	constructor(message: string) {
		super(message, 0);
		this.name = 'NetworkError';
	}
}

/**
 * Raised when the SDK refuses a call before any network request. The caller
 * passed parameters the API cannot serve, such as an unknown filter operator.
 * This is not an `ApiError`; no exchange with the server happened.
 */
export class UsageError extends Error {
	constructor(message: string) {
		super(message);
		this.name = 'UsageError';
	}
}

/** Accepts plain strings and `{message}` items; produces `ValidationError[]`. */
export function normalizeDetails(raw: unknown): ValidationError[] {
	if (!Array.isArray(raw)) {
		return [];
	}
	const items: ValidationError[] = [];
	for (const item of raw) {
		if (typeof item === 'string') {
			items.push({ message: item });
			continue;
		}
		if (typeof item === 'object' && item !== null) {
			const record = item as Record<string, unknown>;
			if (typeof record['message'] === 'string') {
				const entry: ValidationError = { message: record['message'] };
				if (typeof record['field'] === 'string') {
					entry.field = record['field'];
				}
				if (typeof record['code'] === 'string') {
					entry.code = record['code'];
				}
				if (isStringRecord(record['params'])) {
					entry.params = record['params'];
				}
				items.push(entry);
				continue;
			}
		}
		items.push({ message: JSON.stringify(item) });
	}
	return items;
}

function isStringRecord(value: unknown): value is Record<string, string> {
	if (typeof value !== 'object' || value === null) {
		return false;
	}
	return Object.values(value).every((item) => typeof item === 'string');
}

function readMetaString(meta: Record<string, unknown>, key: string): string | null {
	const value = meta[key];
	return typeof value === 'string' ? value : null;
}
