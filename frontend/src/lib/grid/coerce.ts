// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Raw text → typed value for the grid's editable cell types.
 *
 * The client coerces only to build a well-formed PATCH — the server stays
 * the validator, and a 422 still shows on the cell. `coerceScalar` serves
 * the cell editors' text entry; `coercePaste` serves the paste path (Excel →
 * grid) and accepts every form the copy side emits — one grammar per field
 * type feeds editors and paste, so a copied block re-pastes where it came
 * from.
 *
 * Value shapes mirror the stored forms the renderers read:
 * - `string` / `longtext` / `phone` / `url` — text; empty input clears (`null`).
 * - `integer` — whole number; `min` / `max` bounds checked here.
 * - `duration` — free text through `durationMath.parseDuration` (`2h 30m`,
 *   `90`, `26:30:00`); the committed value is seconds, bounds in seconds.
 * - `enum` — exact key first, then exact label, then the case-insensitive
 *   form of either.
 * - `color` — `#RGB` / `#RRGGBB`, normalized to uppercase `#RRGGBB`.
 * - `money` — decimal text → `{ value, currency }` (paste; the currency is
 *   kept from the cell, else the field's declared one).
 * - `date` — `YYYY-MM-DD` verbatim; `datetime` — RFC-3339 normalized to UTC
 *   (a bare wall time resolves through the display zone, the picker's rule).
 * - `period` / `dateperiod` — the two bounds joined with ` → ` (paste; the
 *   copy grammar).
 */
import * as m from '$lib/paraglide/messages';
import { parseDuration } from '$lib/components/primitives/forms/durationMath.js';
import { DECIMAL_RE } from '$lib/components/primitives/forms/moneyFormat.js';
import { daysInMonth, wallToUtcIso } from '$lib/zonedTime.js';
import type { FieldDef } from '$lib/doctype/types.js';

/** Success carries the typed value; failure carries a user-facing message. */
export type CoerceResult = { ok: true; value: unknown } | { ok: false; error: string };

/** The field types this text coercion covers. Other types mount a picker
 *  that emits its own well-formed value and never pass through here. */
const COERCIBLE_TYPES = new Set([
	'string',
	'longtext',
	'phone',
	'url',
	'integer',
	'duration',
	'enum',
	'color'
]);

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
	if (hex.length === 3)
		hex = hex
			.split('')
			.map((c) => c + c)
			.join('');
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
			if (
				(field.min != null && seconds < field.min) ||
				(field.max != null && seconds > field.max)
			) {
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

// ── Paste (Excel → grid) ─────────────────────────────────────────────────

/** Options for one pasted cell's coercion. */
export interface CoercePasteOptions {
	/** The cell's current value — a money cell keeps its currency. */
	current?: unknown;
	/** IANA zone for a bare wall-clock datetime (no explicit offset) — the
	 *  user's display zone, the picker's rule. Defaults to `'UTC'`. */
	timezone?: string;
}

/** The ISO calendar-date grammar — `YYYY-MM-DD`. */
const DATE_RE = /^(\d{4})-(\d{2})-(\d{2})$/;

/**
 * A datetime bound: the date, optional `HH:MM[:SS]` (space or `T` separator,
 * fractional seconds dropped), optional `Z` / `±HH[:]MM` offset.
 */
const DATETIME_RE =
	/^(\d{4}-\d{2}-\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})?)?$/;

/** A validated `YYYY-MM-DD` calendar date, or null. */
function parseDateText(text: string): string | null {
	const match = DATE_RE.exec(text);
	if (!match) return null;
	const month = Number(match[2]);
	const day = Number(match[3]);
	if (month < 1 || month > 12 || day < 1 || day > daysInMonth(Number(match[1]), month)) {
		return null;
	}
	return text;
}

/**
 * One datetime bound → the stored UTC RFC-3339 form. An explicit offset (or
 * `Z`) names the instant directly; a bare wall time resolves through
 * `timezone` — the display zone, the picker's rule; a date-only bound is
 * midnight there. Returns null outside the grammar or on a non-existent
 * calendar date. `JS Date.parse` alone would roll `2026-02-30` over, so the
 * date part validates first.
 */
function parseDatetimeText(text: string, timezone: string): string | null {
	const match = DATETIME_RE.exec(text);
	if (!match) return null;
	const date = parseDateText(match[1]);
	if (date == null) return null;
	const [y, mo, d] = date.split('-').map(Number);
	if (match[2] === undefined) {
		return wallToUtcIso({ y, m: mo, d, h: 0, mi: 0 }, timezone) || null;
	}
	const h = Number(match[2]);
	const mi = Number(match[3]);
	const s = match[4] != null ? Number(match[4]) : 0;
	if (h > 23 || mi > 59 || s > 59) return null;
	const offset = match[5];
	if (offset) {
		const off =
			offset === 'Z'
				? '+00:00'
				: offset.length === 5
					? `${offset.slice(0, 3)}:${offset.slice(3)}`
					: offset;
		const ms = Date.parse(`${date}T${match[2]}:${match[3]}:${match[4] ?? '00'}${off}`);
		return Number.isNaN(ms) ? null : new Date(ms).toISOString();
	}
	return wallToUtcIso({ y, m: mo, d, h, mi }, timezone) || null;
}

/**
 * Normalize a pasted decimal to the canonical `DECIMAL_RE` shape.
 *
 * Clipboard decimals vary by source locale: `1200.50`, `1,234.56` (US),
 * `1 234,56` (fr — spaces and the non-breaking forms strip too), `1'234`
 * (the app's own grouping mark). Spaces and `'` always strip. When `.` and
 * `,` both appear, the rightmost is the decimal mark and the other is
 * grouping. A lone `,` is the decimal mark with 1–2 trailing digits
 * (`12,56`) and thousands grouping with exactly three (`1,234`) — the two
 * shapes Excel's own copy formats produce; anything else fails, so a
 * misread never lands silently in a cell.
 */
export function parseDecimalText(raw: string): string | null {
	const text = raw.replace(/[\s']/g, '');
	const lastDot = text.lastIndexOf('.');
	const lastComma = text.lastIndexOf(',');
	const trailingDigits = text.length - lastComma - 1;
	const commaAsDecimal =
		lastComma >= 0 && lastComma > lastDot && trailingDigits >= 1 && trailingDigits <= 2;
	const decimalChar = commaAsDecimal ? ',' : lastDot > lastComma ? '.' : null;
	let normalized: string;
	if (decimalChar == null) {
		// No decimal mark: the separators left must be thousands grouping —
		// `1,234` / `1,234,567` — or there are none and the text is a bare
		// (possibly signed) integer. A dot, or a lone comma in another shape
		// (`1234,5678`), is junk — the text names no one number.
		const commas = (text.match(/,/g) ?? []).length;
		if (lastDot >= 0 || !(commas === 0 || commas > 1 || (commas === 1 && trailingDigits === 3))) {
			return null;
		}
		normalized = text.replace(/[.,]/g, '');
	} else {
		const groupChar = decimalChar === '.' ? ',' : '.';
		const decIdx = text.lastIndexOf(decimalChar);
		const intPart = text.slice(0, decIdx).split(groupChar).join('');
		const fracPart = text.slice(decIdx + 1);
		if (!/^-?\d+$/.test(intPart) || !/^\d*$/.test(fracPart)) return null;
		normalized = fracPart === '' ? intPart : `${intPart}.${fracPart}`;
	}
	return DECIMAL_RE.test(normalized) ? normalized : null;
}

/**
 * Coerce one pasted cell's text into the field's stored value shape — the
 * paste-side twin of `coerceScalar`. The types without a text editor gain
 * their paste grammar here (money, dates, ranges, booleans, references);
 * the rest delegate. An empty cell clears, so a pasted blank overwrites —
 * the spreadsheet rule. A reference accepts the raw stored id; the server
 * validates it and a 422 still shows on the cell.
 */
export function coercePaste(
	field: FieldDef,
	raw: string,
	options: CoercePasteOptions = {}
): CoerceResult {
	const text = raw.trim();
	switch (field.type) {
		case 'money': {
			if (text === '') return { ok: true, value: null };
			const amount = parseDecimalText(text);
			if (amount == null) return { ok: false, error: m.grid_coerce_money() };
			const current =
				typeof options.current === 'object' && options.current !== null
					? (options.current as Record<string, unknown>)
					: null;
			const currentCurrency = typeof current?.currency === 'string' ? current.currency : '';
			return {
				ok: true,
				value: { value: amount, currency: currentCurrency || field.currency || '' }
			};
		}
		case 'date': {
			if (text === '') return { ok: true, value: null };
			const date = parseDateText(text);
			if (date == null) return { ok: false, error: m.grid_coerce_date() };
			return { ok: true, value: date };
		}
		case 'datetime': {
			if (text === '') return { ok: true, value: null };
			const iso = parseDatetimeText(text, options.timezone ?? 'UTC');
			if (iso == null) return { ok: false, error: m.grid_coerce_datetime() };
			return { ok: true, value: iso };
		}
		case 'period':
		case 'dateperiod': {
			if (text === '') return { ok: true, value: null };
			const arrow = text.indexOf(' → ');
			if (arrow < 0) return { ok: false, error: m.grid_coerce_period() };
			const start = text.slice(0, arrow).trim();
			const end = text.slice(arrow + 3).trim();
			const tz = options.timezone ?? 'UTC';
			const startBound =
				field.type === 'period' ? parseDatetimeText(start, tz) : parseDateText(start);
			const endBound = field.type === 'period' ? parseDatetimeText(end, tz) : parseDateText(end);
			if (startBound == null || endBound == null)
				return { ok: false, error: m.grid_coerce_period() };
			return { ok: true, value: { start: startBound, end: endBound } };
		}
		case 'boolean': {
			const lower = text.toLowerCase();
			if (lower === '') return { ok: true, value: null };
			if (lower === 'true') return { ok: true, value: true };
			if (lower === 'false') return { ok: true, value: false };
			return { ok: false, error: m.grid_coerce_boolean() };
		}
		case 'reference':
			return { ok: true, value: text === '' ? null : text };
		case 'integer': {
			if (text === '') return { ok: true, value: null };
			const normalized = parseDecimalText(text);
			if (normalized == null) return { ok: false, error: m.grid_coerce_integer() };
			return coerceScalar(field, normalized);
		}
		default:
			return coerceScalar(field, raw);
	}
}
