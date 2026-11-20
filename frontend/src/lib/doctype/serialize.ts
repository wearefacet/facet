// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Serialize the doctype editor's typed `DoctypeDef` working copy back into
 * the JSON shape the backend accepts (`Doctype::Update`).
 *
 * This module holds the serialize direction only. The grammar types and the
 * parse direction live in `./types.js`; import the types from there. This
 * file depends on `types.js` — never the reverse.
 */

import type { ActionDef, ArgDef, ChildDef, DoctypeDef, FieldDef, SidecarDef } from './types.js';

// ── Serialization (inverse of parse*) ──────────────────────────────────────
//
// The doctype editor works on a typed `DoctypeDef` working copy; the backend
// (`Doctype::Update`) accepts a `DoctypeDefinition` JSON object. The keys
// the editor does not surface (`search`, `display_name`, `identifier`,
// `scopes`) must be preserved across a save — passing them
// through unchanged from the original raw record avoids clobbering existing
// configuration the editor cannot see.
//
// `keys` (the array-element identifiers added by parse* on every entry) are
// stripped on the way back out: they are an editor-only convenience and the
// backend derives field/child/action names from the object keys.

function omitUndefined<T extends Record<string, unknown>>(obj: T): Record<string, unknown> {
	const out: Record<string, unknown> = {};
	for (const [k, v] of Object.entries(obj)) {
		if (v !== undefined) out[k] = v;
	}
	return out;
}

function serializeFieldDef(field: FieldDef): Record<string, unknown> {
	// `operators` is the backend-derived runtime surface — never sent back,
	// the backend recomputes it from `filters`. `dictionaryValue` is the
	// parsed form of the dictionary's `values:` declaration — it rides back
	// under that key (an enum `values` array and a dictionary entry schema
	// are mutually exclusive, so one key serves both).
	const { key: _key, operators: _operators, dictionaryValue: _dv, ...rest } = field;
	const out: Record<string, unknown> = omitUndefined(rest);
	if (field.values) {
		out.values = field.values.map((v) => {
			const entry: Record<string, unknown> = { key: v.key };
			if (v.label !== undefined) entry.label = v.label;
			if (v.color !== undefined) entry.color = v.color;
			return entry;
		});
	}
	if (field.dictionaryValue) {
		out.values = omitUndefined(serializeFieldDef(field.dictionaryValue)) as Record<string, unknown>;
		delete (out.values as Record<string, unknown>)['key'];
	}
	if (field.items) out.items = serializeFieldDef(field.items);
	if (field.properties) {
		out.properties = Object.fromEntries(field.properties.map((p) => [p.key, serializeFieldDef(p)]));
	}
	return out;
}

function serializeArgDef(arg: ArgDef): Record<string, unknown> {
	const { key: _key, ...rest } = arg;
	const out = omitUndefined(rest);
	if (arg.values) {
		out.values = arg.values.map((v) => {
			const entry: Record<string, unknown> = { key: v.key };
			if (v.label !== undefined) entry.label = v.label;
			if (v.color !== undefined) entry.color = v.color;
			return entry;
		});
	}
	return out;
}

function serializeActionDef(action: ActionDef): Record<string, unknown> {
	const { key: _key, args, ...rest } = action;
	const out: Record<string, unknown> = omitUndefined(rest);
	out.args = Object.fromEntries(args.map((a) => [a.key, serializeArgDef(a)]));
	return out;
}

function serializeChildDef(child: ChildDef): Record<string, unknown> {
	const { key: _key, ...rest } = child;
	return omitUndefined(rest);
}

function serializeSidecarDef(sidecar: SidecarDef): Record<string, unknown> {
	const { key: _key, ...rest } = sidecar;
	const out = omitUndefined(rest);
	// `order` defaults to 0 — omit the default so definitions without an
	// explicit order stay byte-stable across a save.
	if (out['order'] === 0) delete out['order'];
	return out;
}

/**
 * Serialize the editor's typed `DoctypeDef` back into the JSON shape the
 * backend `Doctype::Update` endpoint expects (`PUT /Api/core/DocType/:id`).
 *
 * `preserved` carries keys the editor cannot edit (`search`,
 * `display_name`, `identifier`, `scopes`) so a save does not
 * erase them. Callers should pass the raw record the editor was built from
 * (typically `registry.doctypeDefinitions.get(qualifiedName)`).
 */
export function serializeDoctypeDef(
	def: DoctypeDef,
	preserved: Record<string, unknown> = {}
): Record<string, unknown> {
	const out: Record<string, unknown> = { ...preserved };

	out.doctype = def.doctype;
	out.domain = def.domain;
	if (def.schema_version !== undefined) out.schema_version = def.schema_version;
	if (def.aggregate_root !== undefined) out.aggregate_root = def.aggregate_root;
	if (def.member_of !== undefined) out.member_of = def.member_of;
	if (def.description !== undefined) out.description = def.description;
	if (def.script !== undefined) out.script = def.script;
	if (def.search !== undefined) out.search = def.search;

	// `label` follows the same rule as `color`/`icon` (see below): the editor
	// coalesces `undefined` to '' on the working copy, so a cleared label must
	// erase any value carried over from `preserved` instead of silently
	// keeping it.
	if (!def.label) delete out.label;
	else out.label = def.label;

	// `plural_label` follows the same rule as `label`: a cleared plural must
	// erase any preserved value so consent screens fall back to the pluraliser.
	if (!def.plural_label) delete out.plural_label;
	else out.plural_label = def.plural_label;

	out.fields = Object.fromEntries(def.fields.map((f) => [f.key, serializeFieldDef(f)]));
	out.children = Object.fromEntries(def.children.map((c) => [c.key, serializeChildDef(c)]));
	out.actions = Object.fromEntries(def.actions.map((a) => [a.key, serializeActionDef(a)]));

	// `color` is special-cased: the editor coalesces `undefined` to '' on the
	// working copy so the bindable target is always a defined string. A cleared
	// color must therefore erase any value carried over from `preserved`
	// rather than silently keep it.
	if (!def.color) delete out.color;
	else out.color = def.color;

	// `icon` follows the same rule as `color`: cleared icons must erase any
	// preserved value instead of silently keeping it.
	if (!def.icon) delete out.icon;
	else out.icon = def.icon;

	// Sidecar wiring follows the same rule as `color`/`icon`: a cleared flag
	// or empty list must erase stale values carried over from `preserved`.
	if (def.sidecar === true) out.sidecar = true;
	else delete out.sidecar;

	if (def.sidecars && def.sidecars.length > 0) {
		out.sidecars = Object.fromEntries(def.sidecars.map((s) => [s.key, serializeSidecarDef(s)]));
	} else {
		delete out.sidecars;
	}

	// `migrations` follows the same rule as `sidecars`: a cleared map must
	// erase any stale value carried over from `preserved`.
	if (def.migrations && Object.keys(def.migrations).length > 0) {
		out.migrations = { ...def.migrations };
	} else {
		delete out.migrations;
	}

	if (def.surface !== undefined) out.surface = def.surface;
	else delete out.surface;

	return out;
}
