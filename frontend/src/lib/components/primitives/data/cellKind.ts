// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { FieldDef, FieldType } from '$lib/doctype/types.js';

/**
 * Render kinds the shared `FieldValue` renderer dispatches on.
 *
 * One kind map serves every consumer of typed field values (the table's
 * default cells, the document-view value surfaces). A field type with no
 * dedicated rendering falls back to `text`.
 */
export type FieldValueKind =
	| 'text'
	| 'integer'
	| 'boolean'
	| 'enum'
	| 'money'
	| 'datetime'
	| 'date'
	| 'daterange'
	| 'reference'
	| 'color'
	| 'duration'
	| 'phone'
	| 'url'
	| 'file'
	| 'secret';

/**
 * Field type → render kind.
 *
 * The `Record<FieldType, …>` shape makes the map total: adding a member to
 * {@link FieldType} fails compilation here until the mapping is declared.
 */
const KIND_BY_TYPE: Record<FieldType, FieldValueKind> = {
	string: 'text',
	longtext: 'text',
	integer: 'integer',
	boolean: 'boolean',
	enum: 'enum',
	money: 'money',
	datetime: 'datetime',
	date: 'date',
	dateperiod: 'daterange',
	period: 'daterange',
	object: 'text',
	array: 'text',
	dictionary: 'text',
	reference: 'reference',
	child: 'text',
	data: 'text',
	any: 'text',
	color: 'color',
	duration: 'duration',
	phone: 'phone',
	url: 'url',
	file: 'file',
	secret: 'secret'
};

/**
 * Resolve the render kind for a field type. Absent or unknown types render
 * as text.
 *
 * An `array` field whose `items` are `reference` resolves to the reference
 * kind: the stored value is a JSON array of qualified tokens, the same shape
 * a `collection: true` reference stores. The item type lives on the field
 * definition, so callers pass the definition when they have one. A plain
 * array (or an array without a definition) keeps the text kind.
 */
export function cellKind(
	fieldType: FieldType | null | undefined,
	fieldDef?: FieldDef | null
): FieldValueKind {
	if (fieldType === 'array' && fieldDef?.items?.type === 'reference') return 'reference';
	return (fieldType != null && KIND_BY_TYPE[fieldType]) || 'text';
}

/**
 * Normalize a `reference` field value into the list of qualified tokens to
 * render.
 *
 * A scalar reference renders one token; a collection reference
 * (`collection: true`, see `doc/backend/doctype-system.md`) stores a JSON
 * array and renders one token per element. Blank values, empty arrays, and
 * non-string array elements produce no token — they name no document, and
 * joining an array into one string would fetch a comma-joined id that can
 * never resolve. A non-string scalar keeps the historical `String(value)`
 * form so a malformed row still shows something.
 *
 * A repeated element renders once; the first occurrence wins. The renderer
 * draws one cell per token and keys each cell on its token — a duplicate
 * key makes Svelte throw, and the whole table fails to render.
 */
export function referenceTokens(value: unknown): string[] {
	if (value === null || value === undefined || value === '') return [];
	if (Array.isArray(value)) {
		const tokens = value.filter((v): v is string => typeof v === 'string' && v !== '');
		// `Set` keeps insertion order, so the first occurrence wins.
		return [...new Set(tokens)];
	}
	return [String(value)];
}

/**
 * Plain text for the `text` render kind.
 *
 * Scalars render through `String` (null/undefined render empty, matching
 * the historical `String(value ?? '')`). Arrays and objects render as JSON
 * text: the comma-join of `Array#toString` misrepresents the stored value,
 * and `String(object)` prints the `[object Object]` artifact. This is the
 * fallback contract the document-view surfaces document — objects and
 * arrays fall back to JSON text, never `[object Object]`.
 */
export function plainTextValue(value: unknown): string {
	if (value === null || value === undefined) return '';
	if (Array.isArray(value) || typeof value === 'object') return JSON.stringify(value);
	return String(value);
}
