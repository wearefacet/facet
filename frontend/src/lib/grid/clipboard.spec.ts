// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { serializeTSV, cellCopyText } from './clipboard.js';
import type { FieldDef } from '$lib/doctype/types.js';

/**
 * Unit tests for the grid's copy-side clipboard: the TSV grammar (tabs,
 * embedded newlines, quote doubling) and the raw-form copy text per field
 * type (round-trip clean, empty for absent values).
 */

describe('serializeTSV', () => {
	it('joins cells with tabs and rows with newlines', () => {
		expect(
			serializeTSV([
				['a', 'b'],
				['c', 'd']
			])
		).toBe('a\tb\nc\td');
	});

	it('quotes cells holding tabs, newlines, or quotes, doubling the quotes', () => {
		expect(serializeTSV([['a\tb']])).toBe('"a\tb"');
		expect(serializeTSV([['line1\nline2']])).toBe('"line1\nline2"');
		expect(serializeTSV([['say "hi"']])).toBe('"say ""hi"""');
	});

	it('keeps plain text untouched', () => {
		expect(serializeTSV([['Acme Corp — Platform License', 'open']])).toBe(
			'Acme Corp — Platform License\topen'
		);
		expect(serializeTSV([['commas, fine'], ['semi;colons; fine']])).toBe(
			'commas, fine\nsemi;colons; fine'
		);
	});

	it('serializes an empty block as empty text', () => {
		expect(serializeTSV([])).toBe('');
		expect(serializeTSV([['', '']])).toBe('\t');
	});
});

const field = (type: FieldDef['type']): FieldDef => ({ key: 'f', type }) as FieldDef;

describe('cellCopyText', () => {
	it('copies absent values as empty text', () => {
		expect(cellCopyText(field('string'), null)).toBe('');
		expect(cellCopyText(field('string'), undefined)).toBe('');
		expect(cellCopyText(field('string'), '')).toBe('');
	});

	it('copies booleans as wire strings', () => {
		expect(cellCopyText(field('boolean'), true)).toBe('true');
		expect(cellCopyText(field('boolean'), false)).toBe('false');
	});

	it('copies the money amount, not the display form', () => {
		expect(cellCopyText(field('money'), { value: '120000', currency: 'USD' })).toBe('120000');
		expect(cellCopyText(field('money'), { value: 45000.5, currency: 'EUR' })).toBe('45000.5');
		expect(cellCopyText(field('money'), null)).toBe('');
	});

	it('copies enums, dates, and numbers as their stored form', () => {
		expect(cellCopyText(field('enum'), 'open')).toBe('open');
		expect(cellCopyText(field('date'), '2026-09-30')).toBe('2026-09-30');
		expect(cellCopyText(field('integer'), 60)).toBe('60');
	});

	it('falls back to String for a field-less column', () => {
		expect(cellCopyText(null, 'text')).toBe('text');
		expect(cellCopyText(null, 42)).toBe('42');
	});
});
