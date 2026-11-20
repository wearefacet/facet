// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Seed the editable values bag for `DocumentForm`.
 *
 * The fallback form binds `bind:value` / `bind:checked` straight into the bag.
 * Svelte rejects a `bind:` whose value is `undefined` when the target prop
 * declares a `$bindable` fallback (`props_invalid_value`). Every editable
 * scalar field must therefore hold a defined value before the form renders.
 */

import type { DoctypeDef, FieldDef } from './types.js';

/** Type-appropriate placeholder for an unset scalar field. */
export function emptyValueFor(field: FieldDef): unknown {
	switch (field.type) {
		case 'boolean':
			return false;
		// Duration seeds the same '' blank sentinel as the other scalars
		// (B-310): an untouched field means unset — the patch builder coerces
		// '' to null and the create builder omits it. Zero stays a real,
		// explicitly entered value the DurationInput commits on purpose.
		case 'duration':
			return '';
		// Integer values are bound through type=number inputs as strings; the
		// patch builder coerces '' back to null (treated as unset by the
		// backend). Money uses the same '' sentinel for a cleared amount; the
		// composite `{value, currency}` is rebuilt by `MoneyInput`. The
		// structured fields (object / array / dictionary) bind through the JSON
		// editor with the same '' cleared sentinel; the parsed structure
		// replaces it on a valid edit.
		case 'integer':
		case 'money':
		case 'object':
		case 'array':
		case 'dictionary':
			return '';
		default:
			return '';
	}
}

/** Seed every editable field of the definition through `seed`. */
function seedScalarFields(d: DoctypeDef, seed: (f: FieldDef) => unknown): Record<string, unknown> {
	const out: Record<string, unknown> = {};
	for (const f of d.fields) {
		if (f.type === 'data') continue;
		// Read-only fields are stamped server-side (the backend rejects one in
		// input with a 422) — the bag must never seed a value for them.
		if (f.read_only) continue;
		// Replicated fields are server-populated from their source document —
		// the backend rejects a write to one with a 422, so never seed them.
		if (f.replicate) continue;
		out[f.key] = seed(f);
	}
	return out;
}

/**
 * Seed the values bag for the create form. Every scalar field gets a value —
 * the declared `default` when present, else the neutral per-type placeholder.
 */
export function seedCreateValues(d: DoctypeDef): Record<string, unknown> {
	return seedScalarFields(d, (f) => (f.default !== undefined ? f.default : emptyValueFor(f)));
}

/**
 * Seed the values bag for the edit form: a deep clone of the persisted
 * content over neutral per-type seeds. A scalar key the content does not
 * contain (the field was never set) keeps its seed, so the form never binds
 * `undefined`. The seeds are the neutral empties — not the declared defaults —
 * matching the per-node seeding of the `DvtInput*` components. Defaults stay
 * a create-time concern, so an untouched save cannot write them in.
 */
export function seedEditValues(
	d: DoctypeDef,
	persisted: Record<string, unknown> | null | undefined
): Record<string, unknown> {
	const out = seedScalarFields(d, emptyValueFor);
	Object.assign(out, JSON.parse(JSON.stringify(persisted ?? {})) as Record<string, unknown>);
	// The persisted content carries the server-stamped read-only fields, so
	// the merge above re-introduces the keys the seed pass skipped. Strip
	// them: the bag must never hold a value the patch builder sends back.
	for (const f of d.fields) {
		if (f.read_only || f.replicate) delete out[f.key];
	}
	return out;
}
