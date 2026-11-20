// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { renderValidationError } from '$lib/datasource/validationMessages.js';
import type { ValidationError } from '$lib/datasource/types';

export type FieldErrorMap = Record<string, ValidationError[]>;

export interface GroupedErrors {
	fieldErrors: FieldErrorMap;
	general: ValidationError[];
}

/** Form-level error: the headline plus the field-less detail lines. */
export interface FormError {
	message: string;
	details: string[];
}

/**
 * Group structured validation errors by their top-level field segment.
 *
 * Null/undefined `field` goes into `general`. Errors with a dotted path
 * (`period.start`, `items.3.name`) are grouped under the leading segment
 * (`period`, `items`) so top-level form inputs can attribute nested errors.
 * No string parsing of `message` — only `field` keying.
 */
export function groupFieldErrors(details: ValidationError[] | null | undefined): GroupedErrors {
	const fieldErrors: FieldErrorMap = {};
	const general: ValidationError[] = [];
	if (!details) return { fieldErrors, general };
	for (const d of details) {
		if (!d.field) {
			general.push(d);
			continue;
		}
		const top = d.field.split('.', 1)[0] || d.field;
		(fieldErrors[top] ??= []).push(d);
	}
	return { fieldErrors, general };
}

/**
 * Join the rendered text of all errors grouped under `fieldKey` with `' · '`.
 * Returns `undefined` when no errors are present, so callers can pass the
 * result straight to an input's `error` prop. Each error goes through
 * `renderValidationError` — catalogue text for templated codes, the pasted
 * backend `message` as fallback.
 */
export function joinFieldErrors(
	fieldErrors: FieldErrorMap | null | undefined,
	fieldKey: string
): string | undefined {
	const list = fieldErrors?.[fieldKey];
	return list && list.length > 0
		? list.map((e) => renderValidationError(e)).join(' · ')
		: undefined;
}

/**
 * Builds the form-level error for a `422` payload.
 *
 * Field-less details (script/RBAC/compute/schema) have no input to attach to,
 * so they render under the headline in the form error area. Field-scoped
 * details stay on their inputs: when at least one exists and there are no
 * field-less details, the form area stays quiet (`undefined`). With no details
 * at all, the headline alone is the message.
 */
export function buildFormError(headline: string, grouped: GroupedErrors): FormError | undefined {
	const details = grouped.general.map((e) => renderValidationError(e));
	if (details.length > 0) return { message: headline, details };
	return Object.keys(grouped.fieldErrors).length === 0
		? { message: headline, details: [] }
		: undefined;
}
