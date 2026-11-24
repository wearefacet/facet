// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { FieldDef, FieldType } from '$lib/doctype/types.js';

/**
 * Field-type capabilities of the grid surface, in one place — the sets both
 * the surface (`Grid.svelte`) and the view editor's grid step read.
 */

/**
 * The field types a grid cell can write — the set the per-type cell
 * editors (`grid/editors/`) cover. Containers, `data`, `file`, `secret`,
 * and `any` never edit in the grid — the peek drawer owns them.
 */
export const WRITABLE_FIELD_TYPES: ReadonlySet<FieldType> = new Set([
	'string',
	'longtext',
	'integer',
	'money',
	'date',
	'datetime',
	'period',
	'dateperiod',
	'enum',
	'boolean',
	'reference',
	'color',
	'duration',
	'phone',
	'url'
]);

/**
 * Field-level writability — the type gate plus the schema flags. The grid
 * also gates per column (`editable: false`) and per row (the 403 lock);
 * the system timestamp columns never edit.
 */
export function isWritableField(fieldDef: FieldDef): boolean {
	return WRITABLE_FIELD_TYPES.has(fieldDef.type) && !fieldDef.read_only && !fieldDef.write_only;
}

/**
 * The field types a field aggregate (`sum` / `avg` / `min` / `max`) accepts.
 * Mirrors `List::Aggregate.AGGREGATE_FIELD_TYPES` — the backend answers 422
 * for anything else, so the view editor must never offer one. `count` runs
 * field-free on any column.
 */
export const AGGREGATE_FIELD_TYPES: ReadonlySet<FieldType> = new Set([
	'integer',
	'duration',
	'money'
]);

/** True when the field can carry a field aggregate in the grid's Σ row. */
export function isAggregatableField(fieldDef: FieldDef): boolean {
	return AGGREGATE_FIELD_TYPES.has(fieldDef.type);
}
