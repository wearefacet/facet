// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { cellKind, plainTextValue, referenceTokens, type FieldValueKind } from './cellKind.js';
import type { FieldDef, FieldType } from '$lib/doctype/types.js';

describe('cellKind', () => {
	it('maps every declared field type to its render kind', () => {
		// One entry per `FieldType` member. The count assert below fails when a
		// type is added without a mapping case here.
		const cases: Array<[FieldType, FieldValueKind]> = [
			['string', 'text'],
			['longtext', 'text'],
			['integer', 'integer'],
			['boolean', 'boolean'],
			['enum', 'enum'],
			['money', 'money'],
			['datetime', 'datetime'],
			['date', 'date'],
			['dateperiod', 'daterange'],
			['period', 'daterange'],
			['object', 'text'],
			['array', 'text'],
			['dictionary', 'text'],
			['reference', 'reference'],
			['child', 'text'],
			['data', 'text'],
			['any', 'text'],
			['color', 'color'],
			['duration', 'duration'],
			['phone', 'phone'],
			['url', 'url'],
			['file', 'file'],
			['secret', 'secret']
		];
		expect(cases.length).toBe(23);
		for (const [fieldType, expected] of cases) {
			expect(cellKind(fieldType)).toBe(expected);
		}
	});

	it('sends dateperiod and period to the same daterange kind', () => {
		expect(cellKind('dateperiod')).toBe(cellKind('period'));
	});

	it('falls back to text for an absent type', () => {
		expect(cellKind(null)).toBe('text');
		expect(cellKind(undefined)).toBe('text');
	});

	it('falls back to text for an unknown type string', () => {
		expect(cellKind('nope' as FieldType)).toBe('text');
	});

	it('sends an array of reference through the reference kind', () => {
		// `{type: 'array', items: {type: 'reference'}}` stores qualified tokens —
		// the same shape a `collection: true` reference stores. Without this,
		// the raw JSON array prints on every surface.
		const def: FieldDef = {
			key: 'partners',
			type: 'array',
			items: { key: '(items)', type: 'reference', doctype: 'lab.Partner' }
		};
		expect(cellKind('array', def)).toBe('reference');
	});

	it('keeps plain arrays and array-of-string items on the text kind', () => {
		const strings: FieldDef = {
			key: 'tags',
			type: 'array',
			items: { key: '(items)', type: 'string' }
		};
		expect(cellKind('array', strings)).toBe('text');
		expect(cellKind('array', null)).toBe('text');
		expect(cellKind('array')).toBe('text');
		expect(cellKind('array', { key: 'tags', type: 'array' })).toBe('text');
	});
});

describe('referenceTokens', () => {
	it('wraps a scalar token in a one-element list', () => {
		expect(referenceTokens('crm.Company.1')).toEqual(['crm.Company.1']);
	});

	it('splits a collection reference into one token per element', () => {
		// The 404 shape: an array of qualified ids must never reach a capsule
		// comma-joined (`String(array)`), or the show route 404s.
		expect(referenceTokens(['medtech-prodution.Skill.06A', 'medtech-prodution.Skill.06B'])).toEqual(
			['medtech-prodution.Skill.06A', 'medtech-prodution.Skill.06B']
		);
	});

	it('keeps the first occurrence of a repeated token', () => {
		// F10-A: a stored collection reference can repeat a target. The
		// renderer keys one capsule per token — a duplicate key makes Svelte
		// throw and crashes the whole table. The backend rejects the write
		// now; stored rows keep the shape, so the render side dedupes.
		expect(referenceTokens(['crm.Company.1', 'crm.Company.2', 'crm.Company.1'])).toEqual([
			'crm.Company.1',
			'crm.Company.2'
		]);
	});

	it('collapses a run of identical tokens to one', () => {
		expect(referenceTokens(['lab.Partner.1', 'lab.Partner.1', 'lab.Partner.1'])).toEqual([
			'lab.Partner.1'
		]);
	});

	it('dedupes after the blank filter, keeping first-occurrence order', () => {
		// Not sorted — the first-seen order survives the dedupe.
		expect(referenceTokens(['crm.Company.2', '', 'crm.Company.1', 'crm.Company.2'])).toEqual([
			'crm.Company.2',
			'crm.Company.1'
		]);
	});

	it('drops blank and non-string elements from an array', () => {
		// Mirrors the backend: `ReferenceType#validate` skips null elements.
		expect(referenceTokens(['crm.Company.1', '', null, 42, 'crm.Company.2'])).toEqual([
			'crm.Company.1',
			'crm.Company.2'
		]);
	});

	it('returns an empty list for blank values and empty arrays', () => {
		expect(referenceTokens(null)).toEqual([]);
		expect(referenceTokens(undefined)).toEqual([]);
		expect(referenceTokens('')).toEqual([]);
		expect(referenceTokens([])).toEqual([]);
	});

	it('keeps a non-string scalar renderable through String', () => {
		// A malformed row (the validator rejects these at write time) still
		// shows something instead of an empty cell.
		expect(referenceTokens(42)).toEqual(['42']);
	});
});

describe('plainTextValue', () => {
	it('renders scalars through String, with null/undefined empty', () => {
		expect(plainTextValue('abc')).toBe('abc');
		expect(plainTextValue(42)).toBe('42');
		expect(plainTextValue(true)).toBe('true');
		expect(plainTextValue(null)).toBe('');
		expect(plainTextValue(undefined)).toBe('');
	});

	it('renders arrays as JSON text, never the comma-join', () => {
		expect(plainTextValue(['a', 'b'])).toBe('["a","b"]');
		expect(plainTextValue([])).toBe('[]');
	});

	it('renders objects as JSON text, never [object Object]', () => {
		expect(plainTextValue({ zip: '94105' })).toBe('{"zip":"94105"}');
	});
});
