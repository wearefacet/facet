// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * The ghost new-row line's draft model — the pure logic behind the grid's
 * "type to create" row.
 *
 * The draft holds ONLY the values the user committed. Declared defaults
 * never enter it: they render from the schema (a faint preview of what the
 * server will fill), and the server applies them at create time. The
 * client-side gate mirrors the backend's required-field rule over the
 * columns the view exposes — a required field without a default that no
 * column shows is the server's 422 to answer, not the grid's.
 *
 * No DOM, no datasource — the Vitest `server` project covers it directly.
 */

import type { FieldDef } from '$lib/doctype/types.js';
import { isWritableField } from './fieldTypes.js';
import type { GridColumn } from './types.js';

/** A declared default that counts as "filled" — empty strings and nulls
 *  are absences, not values (the backend treats an explicit null the same
 *  way on create: a required-field refusal). */
function filled(value: unknown): boolean {
	return value !== undefined && value !== null && value !== '';
}

/**
 * The create body from the draft — non-empty values only. Keys with an
 * empty committed value drop, so the server's `ApplyDefaults` sees them as
 * absent (an explicit `null` would refuse a required field instead of
 * filling its default).
 */
export function newRowBody(draft: Record<string, unknown>): Record<string, unknown> {
	const body: Record<string, unknown> = {};
	for (const [key, value] of Object.entries(draft)) {
		if (!filled(value)) continue;
		body[key] = value;
	}
	return body;
}

/**
 * The writable columns' declared defaults — the ghost row's preview
 * values. Read-only and container-typed columns never prefill: the grid
 * cannot write them, and the server would fill them anyway.
 */
export function newRowDefaults(columns: GridColumn[], fields: FieldDef[]): Record<string, unknown> {
	const defaults: Record<string, unknown> = {};
	for (const col of columns) {
		if (col.editable === false) continue;
		const field = fields.find((f) => f.key === col.key);
		if (!field || !isWritableField(field)) continue;
		if (filled(field.default)) defaults[col.key] = field.default;
	}
	return defaults;
}

/**
 * The required-no-default fields the draft still misses — the client-side
 * create gate. Only column-backed writable fields answer here; a required
 * field the view does not show is left to the server's 422 (the grid
 * cannot see it, so marking a cell for it would be a lie).
 */
export function missingRequired(
	draft: Record<string, unknown>,
	columns: GridColumn[],
	fields: FieldDef[]
): FieldDef[] {
	const missing: FieldDef[] = [];
	for (const col of columns) {
		if (col.editable === false) continue;
		const field = fields.find((f) => f.key === col.key);
		if (!field || !field.required || !isWritableField(field)) continue;
		if (filled(field.default)) continue;
		if (filled(draft[col.key])) continue;
		missing.push(field);
	}
	return missing;
}

/** Whether any user value sits in the draft — the ghost row's clean/dirty
 *  split. Defaults do not dirty the row: a row with only the declared
 *  defaults is still the clean prompt. */
export function draftDirty(draft: Record<string, unknown>): boolean {
	for (const value of Object.values(draft)) {
		if (filled(value)) return true;
	}
	return false;
}
