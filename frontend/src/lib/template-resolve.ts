// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Runtime resolution helpers for view templates.
 *
 * These functions resolve `$field` references against document content and
 * format the values for display. The node grammar (the types) stays in
 * `./template-types`.
 */

import { asSecretMarker, humanize } from './doctype/types.js';
import type { DoctypeDef, FieldDef } from './doctype/types.js';
import type { DocumentResponse } from '$lib/datasource/types';
import type { ReferenceFieldMatch, RelationTableColumn } from './template-types.js';

/**
 * Detect whether a template `value` is a single `$field` reference whose
 * declared type is `reference` in the given doctype definition.
 *
 * Returns `null` for interpolated strings, literals, or non-reference fields
 * — only a pure `$field_key` token whose target is a `reference` type matches.
 * This is the branching signal used by `DvtField` to switch from plain-text
 * rendering to a hydrated {@link Capsule}.
 */
export function isReferenceField(
	value: string | undefined,
	def: DoctypeDef | undefined
): ReferenceFieldMatch | null {
	if (!value || !def) return null;
	// A trailing segment allows `$contact.email`-style traversal — but reference
	// fields are always leaf-level, so we only accept the simple `$key` form.
	const m = /^\$([A-Za-z_][A-Za-z0-9_]*)$/.exec(value);
	if (!m) return null;
	const fieldKey = m[1];
	const field = def.fields.find((f) => f.key === fieldKey);
	if (!field || field.type !== 'reference') return null;
	if (typeof field.doctype !== 'string' || field.doctype.length === 0) return null;
	return { fieldKey, qualifiedDoctype: field.doctype };
}

/**
 * Detect a relation-table column whose key is a single field declared as
 * `reference` on the relation doctype. Returns the matched `FieldDef` with
 * its target doctype narrowed to a string — the hydration target for the
 * cell's Capsule. Returns `null` for dotted keys (their leaf renders through
 * the typed-cell traversal instead), unknown fields, and non-reference types.
 */
export function leafReferenceColumn(
	key: string,
	def: DoctypeDef | undefined
): (FieldDef & { doctype: string }) | null {
	if (!def || !key || key.includes('.')) return null;
	const fd = fieldDefFor(def, key);
	if (!fd || fd.type !== 'reference') return null;
	if (typeof fd.doctype !== 'string' || fd.doctype.length === 0) return null;
	return fd as FieldDef & { doctype: string };
}

/**
 * Normalize a relation node's `columns` list at the render boundary.
 *
 * The backend validator rejects malformed columns at authoring time; rows
 * persisted before validation existed can still carry them. A bare string
 * column coerces to `{ key, label: humanized(key) }`. A column without a
 * non-empty string `key` is dropped, and duplicate keys collapse to the
 * first occurrence so the each-block keys stay unique. A malformed template
 * then degrades to a working table instead of a render crash.
 */
export function normalizeRelationColumns(columns: unknown): RelationTableColumn[] {
	if (!Array.isArray(columns)) return [];
	const out: RelationTableColumn[] = [];
	const seen = new Set<string>();
	for (const col of columns) {
		const isObject = col !== null && typeof col === 'object';
		const key = isObject ? (col as { key?: unknown }).key : col;
		if (typeof key !== 'string' || key.length === 0) continue;
		if (seen.has(key)) continue;
		seen.add(key);
		out.push(isObject ? (col as RelationTableColumn) : { key, label: humanize(key) });
	}
	return out;
}

/**
 * Parse a grid layout string into CSS grid-template-columns value.
 * Grammar: space-separated positive integer fractions. Non-conforming
 * tokens fall back to `1fr` so the grid never collapses to an invalid
 * value (which would silently stack columns into a single row).
 *   "1 2"   → "1fr 2fr"
 *   "1 1 1" → "1fr 1fr 1fr"
 *   "3 1"   → "3fr 1fr"
 */
export function parseGridLayout(layout: string): string {
	return layout
		.trim()
		.split(/\s+/)
		.map((token) => (/^[1-9][0-9]*$/.test(token) ? `${token}fr` : '1fr'))
		.join(' ');
}

/**
 * Create a synthetic DocumentResponse with the given data and the same meta
 * as the original document. Used by wrapper nodes (object, array, dict) to
 * shift the resolution root for their children.
 */
export function synthDoc(
	data: Record<string, unknown>,
	document: DocumentResponse
): DocumentResponse {
	return { data, meta: document.meta };
}

/** Convenience: get the content payload from a DocumentResponse. */
export function getDocContent(document: DocumentResponse): Record<string, unknown> {
	return document.data as Record<string, unknown>;
}

/**
 * Format a money-shaped object as `"<currency> <value>"` (for example
 * `"EUR 120000"`). This mirrors the backend display-name templating, which
 * renders a money field the same way. Detection is shape-based, so a
 * computed field that carries the money pair formats too. Returns `null`
 * when the object does not carry a currency ticker and an amount.
 */
function moneyDisplayText(value: object): string | null {
	const o = value as Record<string, unknown>;
	const currency = o['currency'];
	const amount = o['value'];
	if (typeof currency !== 'string' || currency.length === 0) return null;
	if (typeof amount === 'string' && amount.length > 0) return `${currency} ${amount}`;
	if (typeof amount === 'number' && Number.isFinite(amount)) return `${currency} ${amount}`;
	return null;
}

/**
 * Render a resolved field value as display text for a template.
 *
 * - A money-shaped object renders as `"<currency> <value>"`.
 * - A secret marker renders empty. The typed field badge shows the secret
 *   state; the marker itself must never appear as text or JSON.
 * - Any other object or array renders as JSON.
 *
 * Nothing may fall through to `String(value)` here — that prints the JS
 * artifact `[object Object]`.
 */
function toDisplayText(value: unknown): string {
	if (typeof value !== 'object' || value === null) return String(value);
	const money = moneyDisplayText(value);
	if (money !== null) return money;
	if (asSecretMarker(value) !== null) return '';
	return JSON.stringify(value);
}

/**
 * Resolve a single `$field.path` reference against document content.
 * Returns the raw value string on failure so template authors see unresolved refs.
 * A missing or non-string template value resolves to empty text — view
 * templates can arrive malformed (model-authored previews, rows persisted
 * before validation existed) and must never throw during render.
 */
export function resolveValue(
	value: string | null | undefined,
	content: Record<string, unknown>
): string {
	if (value == null) return '';
	if (typeof value !== 'string') return String(value);
	if (!value.startsWith('$')) return value;

	const path = value.slice(1);
	const parts = path.split('.');
	let current: unknown = content;

	for (const part of parts) {
		if (current == null || typeof current !== 'object') return value;
		current = (current as Record<string, unknown>)[part];
	}

	if (current == null) return value;
	return toDisplayText(current);
}

/**
 * Resolve a `$field.path` reference and return the raw value (any type).
 * Returns `undefined` when the field is missing or cannot be resolved.
 * Used by wrapper components (object, array, if, dict) that need the
 * actual object/array/primitive, not a stringified version.
 */
export function resolveRaw(
	field: string | null | undefined,
	content: Record<string, unknown>
): unknown {
	if (field == null || typeof field !== 'string') return undefined;
	const path = field.startsWith('$') ? field.slice(1) : field;
	const parts = path.split('.');
	let current: unknown = content;

	for (const part of parts) {
		if (current == null || typeof current !== 'object') return undefined;
		current = (current as Record<string, unknown>)[part];
	}

	return current;
}

/**
 * Resolve the {@link FieldDef} for a given field key from the doctype
 * definition. Returns `null` when `def` is absent or the field is not found.
 *
 * Used by view-template components to dispatch type-aware rendering
 * (ColorSwatch, Money, RelativeTime, Badge, etc.) instead of showing raw
 * stringified values.
 */
export function fieldDefFor(def: DoctypeDef | undefined, fieldKey: string): FieldDef | null {
	if (!def) return null;
	// Strip leading `$` if present (template values use `$field_key`).
	const key = fieldKey.startsWith('$') ? fieldKey.slice(1) : fieldKey;
	return def.fields.find((f) => f.key === key) ?? null;
}

/**
 * Resolve one token path (without the leading `$`) against document content,
 * with `resolveInterpolated`'s missing-token contract: a path that cannot be
 * resolved renders empty instead of leaking the raw `$token` placeholder.
 */
function resolveTokenText(path: string, content: Record<string, unknown>): string {
	let current: unknown = content;
	for (const part of path.split('.')) {
		if (current == null || typeof current !== 'object') return '';
		current = (current as Record<string, unknown>)[part];
	}
	if (current == null) return '';
	return toDisplayText(current);
}

/** One segment of an interpolated template value: a literal text run or a
 *  single `$token` path (kept without the leading `$`). */
export interface InterpolationSegment {
	text: string;
	isToken: boolean;
}

/**
 * Split an interpolated template value into literal and `$token` segments.
 * The token grammar matches `resolveInterpolated` exactly. Text without
 * tokens returns one literal segment; a missing or non-string value (a
 * malformed, model-authored node) returns `[]` instead of throwing.
 */
export function splitInterpolation(value: string | null | undefined): InterpolationSegment[] {
	if (value == null || typeof value !== 'string') return [];
	const out: InterpolationSegment[] = [];
	let last = 0;
	for (const match of value.matchAll(/\$(\w+(?:\.\w+)*)/g)) {
		const start = match.index;
		if (start === undefined) continue;
		if (start > last) out.push({ text: value.slice(last, start), isToken: false });
		out.push({ text: match[1] ?? '', isToken: true });
		last = start + match[0].length;
	}
	if (last < value.length) out.push({ text: value.slice(last), isToken: false });
	return out;
}

/**
 * Resolve a string with multiple `$field` references (interpolation).
 *
 * - `"$first_name $last_name"` → resolves both fields and joins them
 * - `"Status: $status"` → mixes literal text and field values
 * - `"just text"` → returned as-is
 * - Unknown `$field` references resolve to empty string so the rendered
 *   output stays clean instead of leaking the raw `$token` placeholder
 *   (e.g. a missing `deal_id` shows blank rather than `$deal_id`).
 * - A missing or non-string template value (a malformed, model-authored
 *   node) resolves to empty string instead of throwing.
 */
export function resolveInterpolated(
	value: string | null | undefined,
	content: Record<string, unknown>
): string {
	if (value == null) return '';
	if (typeof value !== 'string') return String(value);
	let out = '';
	for (const seg of splitInterpolation(value)) {
		out += seg.isToken ? resolveTokenText(seg.text, content) : seg.text;
	}
	return out;
}
