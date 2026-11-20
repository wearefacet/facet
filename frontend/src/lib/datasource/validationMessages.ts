// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import * as m from '$lib/paraglide/messages';
import type { ValidationError } from './types.js';

/**
 * The one seam that turns a backend `ValidationError` into user-visible text.
 *
 * When the error's `code` has a catalogue template (`validation_*` keys in
 * `messages/en.json`) and the params the template needs are present, the text
 * renders from the catalogue; otherwise it falls back to the pasted backend
 * `message` — which stays correct English for every producer that does not
 * stamp params. `joinFieldErrors` (per-input errors) and `bannerError`
 * (detail lines) both route through this renderer; nothing else should read
 * `details[].message` for display.
 */
type Template = (error: ValidationError) => string | undefined;

const TEMPLATES: Record<string, Template> = {
	required: () => m.validation_required(),
	read_only: () => m.validation_read_only(),
	reserved: () => m.validation_reserved(),
	unknown_field: () => m.validation_unknown_field(),
	invalid_type: (e) => {
		const expected = e.params?.expected;
		return expected ? m.validation_invalid_type({ expected }) : undefined;
	},
	invalid_format: (e) => {
		const format = e.params?.format;
		return format ? m.validation_invalid_format({ format }) : undefined;
	},
	out_of_range: (e) => {
		const reason = e.params?.reason;
		return reason ? m.validation_out_of_range({ reason }) : undefined;
	},
	unique: () => m.validation_unique(),
	too_long: (e) => {
		const max = e.params?.max;
		return max ? m.validation_too_long({ max }) : undefined;
	},
	inactive_currency: (e) => {
		const value = e.params?.value;
		return value ? m.validation_inactive_currency({ value }) : undefined;
	},
	invalid_reference_format: () => m.validation_invalid_reference_format(),
	reference_target_not_found: (e) => {
		const value = e.params?.value;
		return value ? m.validation_reference_target_not_found({ value }) : undefined;
	}
};

/**
 * Renders one `ValidationError` through the catalogue. Falls back to the
 * pasted `message` when the code has no template, or when the template's
 * params are missing (an older backend, or a producer whose wording does
 * not fit the catalogue).
 */
export function renderValidationError(error: ValidationError): string {
	const template = error.code ? TEMPLATES[error.code] : undefined;
	return template?.(error) ?? error.message;
}
