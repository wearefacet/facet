// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Parse and validate JSON text against a field's declared schema.
 *
 * The structured-input widget (`StructuredInput.svelte`) edits `object`,
 * `array`, and `dictionary` fields as JSON text. This module owns the two
 * steps — syntax and schema — and never mutates anything:
 *
 * - `object` → a plain object; each declared `properties` entry present in
 *   the value must match its sub-schema.
 * - `array` → an array; each item must match the declared `items` schema.
 * - `dictionary` → a plain object; each entry value must match the declared
 *   `dictionaryValue` schema when one exists.
 *
 * The validator is a client-side convenience only — the backend re-validates
 * authoritatively. Undeclared keys and entries pass through unchecked.
 */

import type { FieldDef } from '$lib/doctype/types.js';

/** What the schema expects at one path — the widget turns this into a message. */
export interface SchemaIssue {
	/** Dot path of the offending value, relative to the field (e.g. `address.city`). */
	path: string;
	/** Human-readable expectation (e.g. `a string`, `a number`, `an object`). */
	expected: string;
}

/** The outcome of one parse-and-validate pass. */
export type StructuredParse =
	| { ok: true; value: unknown }
	| { ok: false; reason: 'json' }
	| { ok: false; reason: 'schema'; issue: SchemaIssue };

/** Expectation text for one declared field type. */
function expectationFor(field: FieldDef): string {
	switch (field.type) {
		case 'string':
		case 'longtext':
		case 'enum':
		case 'url':
		case 'phone':
		case 'color':
		case 'date':
		case 'datetime':
		case 'reference':
		case 'child':
			return 'a string';
		case 'integer':
		case 'duration':
			return 'a number';
		case 'boolean':
			return 'true or false';
		case 'money':
			return 'an object with value and currency';
		case 'object':
		case 'dictionary':
		case 'data':
		case 'any':
			return 'an object';
		case 'array':
			return 'an array';
		default:
			return 'a value matching the field schema';
	}
}

/**
 * True for the field types a JSON scalar can satisfy by JS type alone.
 * `any` / `data` / free-form containers accept whatever the JSON carries.
 */
function checkScalar(value: unknown, field: FieldDef, path: string, issue: SchemaIssue): boolean {
	switch (field.type) {
		case 'string':
		case 'longtext':
		case 'enum':
		case 'url':
		case 'phone':
		case 'color':
		case 'date':
		case 'datetime':
		case 'reference':
		case 'child':
			if (typeof value !== 'string') {
				issue.path = path;
				issue.expected = expectationFor(field);
				return false;
			}
			return true;
		case 'integer':
		case 'duration':
			if (typeof value !== 'number' || !Number.isFinite(value)) {
				issue.path = path;
				issue.expected = expectationFor(field);
				return false;
			}
			return true;
		case 'boolean':
			if (typeof value !== 'boolean') {
				issue.path = path;
				issue.expected = expectationFor(field);
				return false;
			}
			return true;
		case 'money':
			if (
				!value ||
				typeof value !== 'object' ||
				Array.isArray(value) ||
				typeof (value as { value?: unknown }).value !== 'string' ||
				typeof (value as { currency?: unknown }).currency !== 'string'
			) {
				issue.path = path;
				issue.expected = expectationFor(field);
				return false;
			}
			return true;
		default:
			// any / data / unknown — the backend validates authoritatively.
			return true;
	}
}

/**
 * Validate one parsed JSON value against a field definition. Fills `issue`
 * and returns `false` on the first mismatch. Containers recurse into their
 * declared sub-schemas; undeclared keys and entries pass through.
 */
function checkValue(value: unknown, field: FieldDef, path: string, issue: SchemaIssue): boolean {
	if (field.type === 'object') {
		if (value === null || typeof value !== 'object' || Array.isArray(value)) {
			issue.path = path;
			issue.expected = expectationFor(field);
			return false;
		}
		if (field.properties) {
			const obj = value as Record<string, unknown>;
			for (const prop of field.properties) {
				if (!(prop.key in obj) || obj[prop.key] === null) continue;
				if (!checkValue(obj[prop.key], prop, `${path}.${prop.key}`, issue)) return false;
			}
		}
		return true;
	}
	if (field.type === 'dictionary') {
		if (value === null || typeof value !== 'object' || Array.isArray(value)) {
			issue.path = path;
			issue.expected = expectationFor(field);
			return false;
		}
		if (field.dictionaryValue) {
			const obj = value as Record<string, unknown>;
			for (const [key, entry] of Object.entries(obj)) {
				if (entry === null) continue;
				if (!checkValue(entry, field.dictionaryValue, `${path}.${key}`, issue)) return false;
			}
		}
		return true;
	}
	if (field.type === 'array') {
		if (!Array.isArray(value)) {
			issue.path = path;
			issue.expected = expectationFor(field);
			return false;
		}
		if (field.items) {
			for (let i = 0; i < value.length; i++) {
				if (value[i] === null) continue;
				if (!checkValue(value[i], field.items, `${path}[${i}]`, issue)) return false;
			}
		}
		return true;
	}
	return checkScalar(value, field, path, issue);
}

/**
 * Parse JSON text and validate it against the field's declared schema.
 *
 * Blank (or whitespace-only) text parses to the `''` cleared sentinel — the
 * same convention the scalar inputs use, so the patch builder omits the field
 * on create and clears it on update. Invalid JSON reports `reason: 'json'`;
 * a schema mismatch reports the first offending path.
 */
export function parseStructured(text: string, field: FieldDef): StructuredParse {
	if (text.trim() === '') return { ok: true, value: '' };

	let parsed: unknown;
	try {
		parsed = JSON.parse(text);
	} catch {
		return { ok: false, reason: 'json' };
	}

	const issue: SchemaIssue = { path: field.key, expected: '' };
	if (!checkValue(parsed, field, field.key, issue)) {
		return { ok: false, reason: 'schema', issue };
	}
	return { ok: true, value: parsed };
}
