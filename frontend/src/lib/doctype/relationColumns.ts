// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Pure column and draft-row helpers for `relation` template nodes.
 *
 * A table column key is either a plain field on the row (`role`) or a dotted
 * path crossing one or more `reference` fields (`contact.email`). Each
 * non-leaf segment resolves to a reference id on the doctype reached so far;
 * the target document is fetched on demand and cached by the caller. Multiple
 * rows sharing the same referenced id reuse the cached fetch. Bounded total
 * by `limit`.
 *
 * This module holds no reactive state — every function takes its inputs as
 * parameters. The hydration fetch lives in `DvtRelation.svelte`.
 */

import type { DocumentResponse } from '$lib/datasource/types.js';
import { fieldDefFor } from '$lib/template-resolve.js';
import type { RelationNode, RelationTableColumn } from '$lib/template-types.js';
import type { ChildDraft } from './childDrafts.js';
import type { DoctypeDef, FieldDef } from './types.js';

/** One row of a relation list — a bare document shape (`data` + `meta`). */
export interface RelationRow {
	meta: { id: string; display_name?: string | null };
	data: Record<string, unknown>;
}

/** Separator between qualified doctype and ref id in the hydration-map keys. */
export const REF_KEY_SEP = '\u0001'; // ASCII control char — cannot appear in doctype ids or doc ids.

/** Build a hydration-map key from a qualified target doctype and a ref id. */
export function refKey(qualified: string, id: string): string {
	return `${qualified}${REF_KEY_SEP}${id}`;
}

/**
 * Split a hydration-map key back into its qualified target doctype and ref
 * id. Returns `null` when the key carries no separator or an empty half.
 */
export function splitRefKey(key: string): { qualified: string; id: string } | null {
	const sepIdx = key.indexOf(REF_KEY_SEP);
	if (sepIdx < 0) return null;
	const qualified = key.slice(0, sepIdx);
	const id = key.slice(sepIdx + 1);
	if (!qualified || !id) return null;
	return { qualified, id };
}

/** Parsed column path — list of segments from the column key. */
export function parseColumnKey(key: string): string[] {
	return key.split('.');
}

/** Resolved table cell — the leaf value plus the `FieldDef` that decides how
 *  `DvtValue` renders it. `fieldDef: null` + `fieldType: null` marks a cell
 *  that could not be resolved (blank / em-dash). */
export interface ResolvedColumnCell {
	value: unknown;
	fieldDef: FieldDef | null;
	fieldType: string | null;
}

/**
 * Walk a column's path against a row, resolving intermediate reference
 * fields and returning the leaf value + its `FieldDef` on the terminal
 * doctype. Returns a blank cell when any intermediate segment is missing or
 * not a `reference`.
 */
export function resolveColumnCell(
	row: RelationRow,
	key: string,
	docs: Map<string, DocumentResponse>,
	defs: Map<string, DoctypeDef>,
	relationDef: DoctypeDef | undefined
): ResolvedColumnCell {
	const parts = parseColumnKey(key);
	if (parts.length === 0) return { value: undefined, fieldDef: null, fieldType: null };
	// Local column (no traversal): read straight from the row's data, type
	// from the relation doctype's def.
	if (parts.length === 1) {
		const fd = fieldDefFor(relationDef, parts[0]);
		return {
			value: row.data?.[parts[0]],
			fieldDef: fd,
			fieldType: fd?.type ?? 'string'
		};
	}
	// Traversal: walk reference fields one by one.
	let currentDoc: DocumentResponse | undefined = undefined;
	let currentDef: DoctypeDef | undefined = relationDef;
	for (let i = 0; i < parts.length - 1; i++) {
		const seg = parts[i];
		const refField = currentDef ? fieldDefFor(currentDef, seg) : null;
		if (!refField || refField.type !== 'reference' || !refField.doctype)
			return { value: undefined, fieldDef: null, fieldType: null };
		// The reference value sits at the root of the current doc's data (one
		// traversal) or, on the first hop, on the row itself.
		const src: Record<string, unknown> | undefined = currentDoc
			? (currentDoc.data as Record<string, unknown>)
			: row.data;
		const refId: unknown = src?.[seg];
		if (typeof refId !== 'string' || refId === '')
			return { value: undefined, fieldDef: null, fieldType: null };
		const resolved = docs.get(refKey(refField.doctype, refId));
		if (!resolved) return { value: undefined, fieldDef: null, fieldType: null };
		currentDoc = resolved;
		currentDef = defs.get(refField.doctype);
	}
	const leaf = parts[parts.length - 1];
	const fd = currentDef ? fieldDefFor(currentDef, leaf) : null;
	const leafData = currentDoc?.data as Record<string, unknown> | undefined;
	return {
		value: leafData ? leafData[leaf] : undefined,
		fieldDef: fd,
		fieldType: fd?.type ?? 'string'
	};
}

/**
 * Reference doctypes reached by any column key (e.g. `['crm.Contact']`).
 * Only the first hop of each column is collected — the hydration fetch
 * resolves first-hop references only.
 */
export function columnRefTargets(
	template: Pick<RelationNode, 'columns'>,
	relationDef: DoctypeDef | undefined
): string[] {
	if (!relationDef) return [];
	const out = new Set<string>();
	for (const col of template.columns ?? []) {
		const parts = parseColumnKey(col.key);
		const currentDef = relationDef;
		for (let i = 0; i < parts.length - 1; i++) {
			const fd = fieldDefFor(currentDef, parts[i]);
			if (!fd || fd.type !== 'reference' || !fd.doctype) break;
			out.add(fd.doctype);
			// We stop schema validation here — deeper traversals just borrow the
			// first hop's target definition; the renderer treats unsupported
			// multi-hop paths as blank (em-dash), matching DVT's blank policy.
			continue;
		}
	}
	return [...out];
}

/** Whether the table view crosses any reference field (triggers hydration). */
export function tableNeedsHydration(
	template: Pick<RelationNode, 'columns'>,
	viewMode: string
): boolean {
	return (
		viewMode === 'table' && (template.columns ?? []).some((c) => parseColumnKey(c.key).length > 1)
	);
}

/**
 * Resolve the inline-toggle target for a relation table column. Returns the
 * boolean `FieldDef` when the column is marked `editable`, its key is a
 * single segment (the leaf lives on the row document itself), and the field
 * on the relation doctype is a plain boolean — not `read_only` /
 * `write_only`. Returns `null` otherwise: dotted keys resolve their leaf on
 * a referenced document (a mutation target the toggle does not write), and
 * non-boolean fields have no toggle. Callers layer the remaining gates on
 * top — the viewer's `update` permission and the read-only-surface rule.
 */
export function toggleTarget(
	col: RelationTableColumn,
	relationDef: DoctypeDef | undefined
): FieldDef | null {
	if (col.editable !== true || !relationDef) return null;
	if (parseColumnKey(col.key).length !== 1) return null;
	const fd = fieldDefFor(relationDef, col.key);
	if (!fd || fd.type !== 'boolean' || fd.read_only || fd.write_only) return null;
	return fd;
}

/** The row's reference value for capsule labels — `undefined` when unset. */
export function rowCapsuleReference(
	row: RelationRow,
	referenceField: string | undefined
): string | undefined {
	if (!referenceField) return undefined;
	const v = row.data?.[referenceField];
	return typeof v === 'string' && v.length > 0 ? v : undefined;
}

/** A parsed `"<domain>.<Doctype>.<id>"` reference id. */
export interface ParsedReferenceId {
	domain: string;
	doctype: string;
	id: string;
}

/**
 * Convert a reference id (`"<domain>.<Doctype>.<id>"`) into its click-event
 * parts. Returns `null` when the id is not a qualified reference — bare ids
 * carry no domain/doctype and cannot be opened. The `id` member keeps the
 * full qualified string, since `ReferenceClickEvent` consumers resolve it.
 */
export function parseReferenceId(refId: string): ParsedReferenceId | null {
	const first = refId.indexOf('.');
	if (first < 1) return null;
	const second = refId.indexOf('.', first + 1);
	if (second < 0) return null;
	return {
		domain: refId.slice(0, first),
		doctype: refId.slice(first + 1, second),
		id: refId
	};
}

/**
 * Build a draft context from a loaded row. Deep clone so inner input
 * `bind:value` writes (which mutate `values[field]` of the draft) never
 * leak back into the cached `rows` array.
 */
export function rowToDraft(row: RelationRow): ChildDraft {
	return {
		id: row.meta.id,
		values: JSON.parse(JSON.stringify(row.data ?? {})) as Record<string, unknown>
	};
}

/** Type-appropriate placeholder for an unset scalar field (mirrors DocumentForm). */
export function emptyValueFor(field: { type: string }): unknown {
	switch (field.type) {
		case 'boolean':
			return false;
		case 'duration':
			return 0;
		case 'integer':
		case 'money':
			return '';
		default:
			return '';
	}
}

/** Build a typed empty form values bag from the relation doctype definition. */
export function seedEmptyDraft(d: DoctypeDef | undefined): Record<string, unknown> {
	const out: Record<string, unknown> = {};
	if (!d) return out;
	for (const f of d.fields) {
		if (f.type === 'data' || f.type === 'array' || f.type === 'object') continue;
		out[f.key] = f.default !== undefined ? f.default : emptyValueFor(f);
	}
	return out;
}

/**
 * Build the fake `DocumentResponse` the inner `DocumentViewTemplate` reads
 * for one draft row. The meta carries the relation doctype's identity and
 * schema version; `version: 0` marks an unsaved draft.
 */
export function rowDocument(
	draft: ChildDraft,
	relationParts: { domain: string; doctype: string } | null,
	schemaVersion: number
): DocumentResponse {
	return {
		data: draft.values,
		meta: {
			id: draft.id,
			mid: draft.id,
			domain: relationParts?.domain ?? '',
			doc_type: relationParts?.doctype ?? '',
			version: 0,
			schema_version: schemaVersion,
			display_name: null,
			created_at: '',
			updated_at: ''
		}
	};
}
