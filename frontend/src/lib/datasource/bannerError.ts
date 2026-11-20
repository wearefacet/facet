// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { DataSourceError, type ValidationError } from './types.js';
import { renderValidationError } from './validationMessages.js';

/**
 * Banner-ready error detail lines for pages that surface an `AlertBanner`
 * without per-input error slots (wizard steps, app detail tabs).
 *
 * The `DataSourceError.message` (e.g. "Document validation failed") is the
 * headline; each structured `detail` becomes a prefixed detail line so the
 * user sees what actually failed (`set — is not a defined field`) instead of
 * the laconic headline alone.
 *
 * Non-`DataSourceError` errors fall back to the error's message with no
 * detail lines.
 */
export interface BannerError {
	message: string;
	details: string[];
}

/**
 * Human-readable message for an unknown thrown value. An `Error` yields its
 * `message`; anything else yields `fallback` when one is given, else the
 * string form of the value. Call sites that previously wrote
 * `err instanceof Error ? err.message : 'Fallback'` cut to this helper.
 */
export function errorMessage(err: unknown, fallback?: string): string {
	if (err instanceof Error) return err.message;
	if (fallback !== undefined) return fallback;
	return String(err);
}

function formatLine(error: ValidationError): string {
	const text = renderValidationError(error);
	return error.field ? `${error.field} — ${text}` : text;
}

export function toBannerError(err: unknown): BannerError {
	if (err instanceof DataSourceError) {
		const details = (err.details ?? []).map(formatLine);
		return { message: err.message, details };
	}
	return {
		message: errorMessage(err),
		details: []
	};
}
