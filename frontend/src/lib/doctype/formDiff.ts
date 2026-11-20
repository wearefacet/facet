// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Build a PATCH body for `DocumentRef.update()` from an edit-form values bag.
 *
 * The form's `input-*` nodes bind string values into the `values` object. The
 * real backend (`Document::Update`) deep-merges the PATCH body over the
 * current content and re-validates types, so we must coerce edited strings
 * back to their declared field types (integer/duration → number, money →
 * `{value, currency}` object, boolean → boolean, url → absolute — a dotted
 * bare host gets the scheme prepended, the same rule the backend's
 * `UrlType#normalize` applies) before sending. Enum/string/datetime/
 * reference/color stay strings and money stays the composite
 * `{value: string, currency: string}` object.
 *
	 * The patch is a plain object mirroring the document content shape — only the
	 * fields present in the form are included, so untouched fields are not
	 * clobbered by the deep-merge. A blank form value (`''`, the cleared sentinel
	 * the form seeds) becomes `null` on update — for scalars and for structured
	 * object fields — because a `null` key is the merge-patch signal to clear a
	 * field. Nested objects (edited through `DvtObject`) that hold a real object
	 * are sent as the full sub-object so the merge replaces the branch cleanly.
	 *
	 * When the persisted content is passed, the patch is minimal: a key whose
	 * coerced value equals the persisted value is omitted. The edit form seeds
	 * its values bag from the persisted content, so an untouched save emits an
	 * empty patch — required because some doctypes carry Lua-guarded immutable
	 * fields (`iam.Roles.name`, `app.App.slug`, …) whose `update` hook rejects
	 * any patch that carries the key, changed or not. Same-value keys that do
	 * slip through cost nothing: the backend's own JsonDiff folds them into a
	 * no-op mutation.
 */

import type { DoctypeDef, FieldDef } from './types.js';
import { ensureAbsoluteUrl } from './urlValue.js';

/** A coerced value or `undefined` to skip (no change). */
type Coerced = unknown;

/** Coerce a single scalar value to the declared field type. */
function coerceScalar(value: unknown, field: FieldDef): Coerced {
	// Empty string → null (treat blank inputs as cleared). Preserve real
	// booleans/numbers that came from the initial clone untouched.
	if (value === '' || value === null) return null;

	switch (field.type) {
		case 'money': {
			// Money lives as the composite `{value, currency}` object the backend's
			// `MoneyType` validates. `value` is a canonical decimal *string* (never a
			// JS number — `MoneyType#validate` rejects a numeric `value` member with
			// `invalid_type`). An empty amount was already coerced to `null` above;
			// here we normalize a possibly-loosely-typed object to the canonical shape
			// so the deep-merge lands a clean, validatable money object.
			if (value && typeof value === 'object') {
				const v = (value as { value?: unknown }).value;
				const c = (value as { currency?: unknown }).currency;
				if (v == null || c == null) return value;
				return { value: String(v), currency: String(c) };
			}
			return value;
		}
		case 'integer':
		case 'duration': {
			if (typeof value === 'number') return value;
			if (typeof value === 'string') {
				const n = Number(value);
				return Number.isNaN(n) ? value : n;
			}
			return value;
		}
		case 'boolean': {
			if (typeof value === 'boolean') return value;
			if (typeof value === 'string') {
				if (value === 'true') return true;
				if (value === 'false') return false;
			}
			return Boolean(value);
		}
		case 'url': {
			// The backend's `UrlType` only accepts absolute URLs; a dotted bare
			// host typed into the form gets the default scheme before it hits
			// the wire — the identical completion rule `UrlType#normalize`
			// applies at every entry point (B-294). A dotless scheme-less value
			// (`not-a-url`) is NOT completed: it passes through and the
			// backend's 422 refuses it, same as REST. A whitespace-only value
			// collapses to `''` → the blank contract above already turned `''`
			// into `null`, so map it there too (cleared, not an invalid empty
			// URL).
			if (typeof value !== 'string') return value;
			const fixed = ensureAbsoluteUrl(value);
			return fixed === '' ? null : fixed;
		}
		default:
			// string, longtext, enum, date, datetime, period, dateperiod, reference, color, any
			return value;
	}
}

/** Coerce a value that may be a nested object, recursing through properties. */
function coerceValue(value: unknown, field: FieldDef): Coerced {
	// Object field with declared properties → recurse into each sub-field.
	if (field.type === 'object' && field.properties && field.properties.length > 0) {
		// The form seeds a never-edited structured field with the '' sentinel.
		// Send null for it: the merge patch removes a null key, the same clear
		// rule scalars use. A '' on the wire fails the backend object check.
		// Any other non-object passes through, so the backend rejects it.
		if (value === '' || value == null) return null;
		if (typeof value !== 'object') return value;
		const src = value as Record<string, unknown>;
		const out: Record<string, unknown> = {};
		for (const prop of field.properties) {
			if (prop.key in src) out[prop.key] = coerceValue(src[prop.key], prop);
		}
		// Preserve any extra keys the form didn't describe (free-form entries).
		for (const [k, v] of Object.entries(src)) {
			if (!(k in out)) out[k] = v;
		}
		return out;
	}
	return coerceScalar(value, field);
}

/**
 * Structural value equality for patch diffing.
 *
 * `null` and `undefined` read as the same "no value" state; everything else
 * compares through its JSON form, so a cloned bag value equals the persisted
 * value it was seeded from. Array order is significant; plain-object key
 * order is compared as-is — both sides are JSON clones of the same source in
 * the edit-form flow, and a same-value key that slips through is folded into
 * a no-op by the backend's own JsonDiff.
 */
export function sameValue(a: unknown, b: unknown): boolean {
	return JSON.stringify(a ?? null) === JSON.stringify(b ?? null);
}

/**
 * Build the PATCH body from the edited values bag and the doctype definition.
 *
 * Only fields declared in the definition AND present in `values` are emitted,
 * so unedited fields (absent from the form) are left untouched by the
 * deep-merge. Returns `{}` when nothing changed.
 *
 * When `persisted` is provided, the patch is minimal: a key whose coerced
 * value equals the persisted value is omitted (see the header note on
 * Lua-guarded immutable fields). The edit form passes the loaded document's
 * content; child-draft persistence and other callers omit it and receive the
 * full coerced bag.
 *
 * Empty string inputs are coerced to `null` (structured object fields
 * included) — on **update** this is the correct "clear the field" signal.
 * For **create** use {@link buildFormCreate} instead, which omits empty
 * values so the backend's required-field validation fires and returns the
 * missing-field list as a 422.
 */
export function buildFormPatch(
	values: Record<string, unknown>,
	def: DoctypeDef,
	persisted?: Record<string, unknown> | null
): Record<string, unknown> {
	const out: Record<string, unknown> = {};
	const byKey = new Map<string, FieldDef>();
	for (const f of def.fields) byKey.set(f.key, f);

	for (const [key, raw] of Object.entries(values)) {
		const field = byKey.get(key);
		if (!field) {
			// Unknown to the schema — pass through (the backend will reject if
			// it doesn't accept unknown fields, but we don't silently drop),
			// unless it repeats the persisted value.
			if (persisted && sameValue(raw, persisted[key])) continue;
			out[key] = raw;
			continue;
		}
		// Skip computed (`data`) fields — never re-send them on update. Read-only
		// fields are server-stamped: sending one back is rejected with a 422.
		// Replicated fields are server-populated from their source document —
		// sending one back is rejected with a 422 too.
		if (field.type === 'data' || field.read_only || field.replicate) continue;
		const coerced = coerceValue(raw, field);
		if (persisted && sameValue(coerced, persisted[key])) continue;
		out[key] = coerced;
	}

	return out;
}

/**
 * Whether a coerced scalar should be omitted from a **create** payload.
 *
 * On create, sending `null` / `''` for an unfilled field is wrong: the
 * backend's `Document::Validation#check_field_types` skips `null` values
 * entirely (`next if value.raw.nil?`), and a present-but-null key also
 * satisfies the required-field presence check — so a missing required field
 * silently slips through and crashes downstream where an unsafe cast
 * (e.g. `JSON::Any#as_s`) hits the nil. Omitting the field lets the backend
 * report "Required field 'X' is missing" as a clean 422 with field details.
 */
function isBlankForCreate(coerced: unknown): boolean {
	return coerced === null || coerced === undefined || coerced === '';
}

/**
 * Build the create body for a new document from the form values bag.
 *
 * Unlike {@link buildFormPatch}, blank values are **omitted** (not sent as
 * `null`) so the backend's required-field validation fires and returns the
 * list of missing fields as a 422. Non-blank values are type-coerced the
 * same way as on update.
 */
export function buildFormCreate(
	values: Record<string, unknown>,
	def: DoctypeDef
): Record<string, unknown> {
	const out: Record<string, unknown> = {};
	const byKey = new Map<string, FieldDef>();
	for (const f of def.fields) byKey.set(f.key, f);

	for (const [key, raw] of Object.entries(values)) {
		const field = byKey.get(key);
		if (!field) {
			// Unknown to the schema — pass through only if non-blank.
			if (!isBlankForCreate(raw)) out[key] = raw;
			continue;
		}
		// Skip computed (`data`) fields — never set them on create. Read-only
		// fields are server-stamped: sending one is rejected with a 422.
		// Replicated fields are server-populated from their source document —
		// sending one is rejected with a 422 too.
		if (field.type === 'data' || field.read_only || field.replicate) continue;

		const coerced = coerceValue(raw, field);
		// Omit blanks so required-field validation reports them as missing.
		if (isBlankForCreate(coerced)) continue;
		out[key] = coerced;
	}

	return out;
}
