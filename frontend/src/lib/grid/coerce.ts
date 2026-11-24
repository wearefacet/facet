// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Raw text → typed value for the grid's editable cell types.
 *
 * The client coerces only to build a well-formed PATCH — the server stays
 * the validator, and a 422 still shows on the cell. The same parser will
 * serve the paste path (phase 3), so one grammar feeds both editors and
 * paste.
 *
 * Value shapes mirror the stored forms the renderers read:
 * - `string` / `longtext` / `phone` / `url` — text; empty input clears (`null`).
 * - `integer` — whole number; `min` / `max` bounds checked here.
 * - `duration` — free text through `durationMath.parseDuration` (`2h 30m`,
 *   `90`, `26:30:00`); the committed value is seconds, bounds in seconds.
 * - `enum` — exact key first, then exact label, then the case-insensitive
 *   form of either.
 * - `color` — `#RGB` / `#RRGGBB`, normalized to uppercase `#RRGGBB`.
 */
import * as m from '$lib/paraglide/messages';
import { parseDuration } from '$lib/components/primitives/forms/durationMath.js';
import type { FieldDef } from '$lib/doctype/types.js';

/** Success carries the typed value; failure carries a user-facing message. */
export type CoerceResult = { ok: true; value: unknown } | { ok: false; error: string };

/** The field types this text coercion covers. Other types mount a picker
 *  that emits its own well-formed value and never pass through here. */
const COERCIBLE_TYPES = new Set(['string', 'longtext', 'phone', 'url', 'integer', 'duration', 'enum', 'color']);

/** `#RGB` / `#RRGGBB`, with or without the leading hash. */
const HEX_RE = /^#(?:[0-9a-fA-F]{3}|[0-9a-fA-F]{6})$/;

/**
 * Parse a colour entry into the normalized stored form — `#RRGGBB`,
 * uppercase. Expands the 3-digit form. Returns `null` when the text is not
 * a hex colour.
 */
export function parseHexColor(raw: string): string | null {
	const text = raw.trim();
	if (text === '') return null;
	const withHash = text.startsWith('#') ? text : `#${text}`;
	if (!HEX_RE.test(withHash)) return null;
	let hex = withHash.slice(1);
	if (hex.length === 3) hex = hex.split('').map((c) => c + c).join('');
	return `#${hex.toUpperCase()}`;
}

/**
 * Structural value equality for cell writes — `null` / `undefined` count as
 * one blank, scalars compare directly, objects (`money`, `period`) compare
 * key-by-key in a stable order. Guards the no-op: an unchanged value never
 * sends a PATCH.
 */
export function valueEquals(a: unknown, b: unknown): boolean {
	if (a === b) return true;
	if (a == null && b == null) return true;
	if (a == null || b == null) return false;
	if (typeof a === 'object' && typeof b === 'object') {
		return stableKey(a) === stableKey(b);
	}
	return false;
}

/** A serialization whose key order never leaks into the comparison. */
function stableKey(v: unknown): string {
	if (Array.isArray(v)) return `[${v.map(stableKey).join(',')}]`;
	if (v !== null && typeof v === 'object') {
		const entries = Object.entries(v as Record<string, unknown>).sort(([a], [b]) =>
			a.localeCompare(b)
		);
		return `{${entries.map(([k, val]) => `${JSON.stringify(k)}:${stableKey(val)}`).join(',')}}`;
	}
	return JSON.stringify(v) ?? 'undefined';
}

/** The shared bounds wording — the declared bounds, one of three forms. */
function boundsError(field: FieldDef): { ok: false; error: string } {
	if (field.min != null && field.max != null) {
		return {
			ok: false,
			error: m.grid_coerce_bounds_between({ min: String(field.min), max: String(field.max) })
		};
	}
	if (field.min != null) {
		return { ok: false, error: m.grid_coerce_bounds_min({ min: String(field.min) }) };
	}
	return { ok: false, error: m.grid_coerce_bounds_max({ max: String(field.max ?? '') }) };
}

/**
 * Coerce one cell's text into the field's stored value shape. An
 * unsupported field type fails — the caller should not have opened a text
 * editor for it.
 */
export function coerceScalar(field: FieldDef, raw: string): CoerceResult {
	if (!COERCIBLE_TYPES.has(field.type)) {
		return { ok: false, error: m.grid_coerce_type({ type: field.type }) };
	}
	const text = raw.trim();
	switch (field.type) {
		case 'string':
		case 'longtext':
		case 'phone':
		case 'url':
			// An empty input clears the field. Inner newlines survive on
			// `longtext` — only the ends are trimmed.
			return { ok: true, value: text === '' ? null : text };
		case 'integer': {
			if (text === '') return { ok: true, value: null };
			const n = Number(text);
			if (!Number.isInteger(n)) return { ok: false, error: m.grid_coerce_integer() };
			if ((field.min != null && n < field.min) || (field.max != null && n > field.max)) {
				return boundsError(field);
			}
			return { ok: true, value: n };
		}
		case 'duration': {
			if (text === '') return { ok: true, value: null };
			const seconds = parseDuration(text);
			if (seconds == null) return { ok: false, error: m.grid_coerce_duration() };
			if ((field.min != null && seconds < field.min) || (field.max != null && seconds > field.max)) {
				return boundsError(field);
			}
			return { ok: true, value: seconds };
		}
		case 'enum': {
			if (text === '') return { ok: true, value: null };
			const values = field.values ?? [];
			const lower = text.toLowerCase();
			const match =
				values.find((e) => e.key === text) ??
				values.find((e) => e.label === text) ??
				values.find((e) => e.key.toLowerCase() === lower) ??
				values.find((e) => e.label?.toLowerCase() === lower);
			if (!match) return { ok: false, error: m.grid_coerce_enum() };
			return { ok: true, value: match.key };
		}
		case 'color': {
			if (text === '') return { ok: true, value: null };
			const hex = parseHexColor(text);
			if (hex == null) return { ok: false, error: m.grid_coerce_color() };
			return { ok: true, value: hex };
		}
		default:
			return { ok: false, error: m.grid_coerce_type({ type: field.type }) };
	}
}
