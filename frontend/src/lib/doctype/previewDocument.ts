// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Preview document generator for Builder view-template previews.
 *
 * Produces a deterministic, schema-derived {@link DocumentResponse} so that
 * a `core.DocumentView` template can be rendered against a doctype definition
 * without hitting the backend. The output is stable across renders (no random
 * data) so the preview does not flicker between kind switches.
 *
 * Reference-typed fields produce a synthetic qualified id (`"<doctype>.sample"`)
 * plus a sibling `display_name`-style field used by `DvtField`'s plain-text
 * dispatch. Real reference hydration is out of scope for the v1 preview.
 */

import type { DocumentResponse, DocumentMeta } from '$lib/datasource/types';
import { humanize, type DoctypeDef, type FieldDef } from './types.js';

/** The five `core.DocumentView` kinds. */
export const VIEW_KINDS = ['view', 'form', 'inline', 'card', 'quickView'] as const;
export type ViewKind = (typeof VIEW_KINDS)[number];

/**
 * Build a stable mock value for a single {@link FieldDef}.
 *
 * Honors `default` when present. Skips computed (`data` type) fields because
 * they are not user-authored and would clutter the preview with placeholders.
 */
function mockField(field: FieldDef): unknown {
	if (field.default !== undefined) {
		return field.default;
	}

	switch (field.type) {
		case 'boolean':
			return true;
		case 'integer':
			return mockInteger(field.min, field.max);
		case 'money':
			// Stored shape matches the backend `Money` type: a decimal string
			// `value` (never a JS number, which `MoneyType` rejects) + a ticker.
			return { value: '4200', currency: field.currency ?? 'USD' };
		case 'datetime':
			return '2025-01-15T09:30:00Z';
		case 'color':
			return '#3b82f6';
		case 'enum': {
			const first = field.values?.[0];
			return first ? first.key : 'sample';
		}
		case 'object':
			return mockObjectFields(field.properties ?? []);
		case 'array':
			return field.items
				? [mockField(field.items), mockField(field.items)]
				: ['Sample item', 'Sample item'];
		case 'dictionary':
			return { key_a: 'Sample value', key_b: 'Sample value' };
		case 'reference':
			// No hydration in v1 — emit a synthetic qualified id so the value
			// renders as plain text inside `DvtField` (the doctype `def` is
			// passed but no `driver`, so `DvtField` does not switch to the
			// hydrated branch).
			return `${field.doctype ?? 'core.Doctype'}.sample`;
		case 'child':
		case 'data':
			// Computed / managed fields are not previewable.
			return undefined;
		case 'string':
		case 'longtext':
		case 'any':
		default:
			return mockSampleString(field);
	}
}

/** Pick a representative integer in `[min, max]`. */
function mockInteger(min?: number, max?: number): number {
	if (typeof min === 'number' && typeof max === 'number') return Math.round((min + max) / 2);
	if (typeof min === 'number') return min + 10;
	if (typeof max === 'number') return Math.max(0, max - 10);
	return 100;
}

/** Build a representative string label from the field's title or key. */
function mockSampleString(field: FieldDef): string {
	const label = field.title ?? humanize(field.key);
	return `Sample ${label}`;
}

/** Recurse into sub-fields of an object (root or nested). */
function mockObjectFields(fields: FieldDef[]): Record<string, unknown> {
	const out: Record<string, unknown> = {};
	for (const sub of fields) {
		const value = mockField(sub);
		if (value !== undefined) out[sub.key] = value;
	}
	return out;
}

/**
 * Generate a synthetic {@link DocumentResponse} that previews a doctype's
 * view templates. User-supplied `overrides` win over the generated values.
 */
export function previewDocument(
	def: DoctypeDef,
	overrides: Record<string, unknown> = {}
): DocumentResponse {
	const data = mockObjectFields(def.fields);
	return {
		data: { ...data, ...overrides },
		meta: {
			id: `${def.domain}.${def.doctype}.sample`,
			mid: `${def.domain}.${def.doctype}.sample`,
			domain: def.domain,
			doc_type: def.doctype,
			version: 1,
			schema_version: def.schema_version ?? 1,
			display_name: `Sample ${def.doctype}`,
			created_at: '2025-01-15T09:30:00Z',
			updated_at: '2025-01-15T09:30:00Z'
		} satisfies DocumentMeta
	};
}

/**
 * Build the default view-template node for a doctype definition. Used as the
 * fallback preview when no `core.DocumentView` exists for a kind yet, so the
 * user can see a starting point before authoring a custom template.
 *
 * Output: a single `col` listing one `field` node per user-displayable field,
 * with `$field_key` resolutions.
 */
export function defaultViewTemplate(def: DoctypeDef): import('$lib/template-types').TemplateNode {
	const children = def.fields
		.filter((f) => f.type !== 'child' && f.type !== 'data')
		.map((f) => ({
			type: 'field' as const,
			label: f.title ?? humanize(f.key),
			value: `$${f.key}`
		}));

	if (children.length === 0) {
		return { type: 'label', value: `No fields on ${def.doctype}` };
	}

	return {
		type: 'col',
		children
	};
}
