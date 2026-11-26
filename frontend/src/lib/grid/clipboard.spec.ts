// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { serializeTSV, parseTSV, cellCopyText } from './clipboard.js';
import type { FieldDef } from '$lib/doctype/types.js';

/**
 * Unit tests for the grid's clipboard grammar: the TSV serialization (tabs,
 * embedded newlines, quote doubling), the raw-form copy text per field type
 * (round-trip clean, empty for absent values), and the paste-side parser
 * that accepts the same grammar plus Excel's copy dialect (CRLF rows).
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

describe('parseTSV', () => {
	it('splits tab cells and newline rows', () => {
		expect(parseTSV('a\tb\nc\td')).toEqual([
			['a', 'b'],
			['c', 'd']
		]);
	});

	it('accepts Excel CRLF row breaks and a lone CR', () => {
		expect(parseTSV('a\tb\r\nc\td')).toEqual([
			['a', 'b'],
			['c', 'd']
		]);
		expect(parseTSV('a\rb')).toEqual([['a'], ['b']]);
	});

	it('unescapes quoted cells — doubled quotes and embedded newlines', () => {
		expect(parseTSV('"a\tb"\tc')).toEqual([['a\tb', 'c']]);
		expect(parseTSV('"line1\nline2"\td')).toEqual([['line1\nline2', 'd']]);
		expect(parseTSV('"say ""hi"""')).toEqual([['say "hi"']]);
	});

	it('keeps trailing empty cells and pads short rows to a rectangle', () => {
		expect(parseTSV('a\t')).toEqual([['a', '']]);
		expect(parseTSV('a\tb\nc')).toEqual([
			['a', 'b'],
			['c', '']
		]);
	});

	it('drops one trailing row break but keeps interior blank rows', () => {
		expect(parseTSV('a\tb\n')).toEqual([['a', 'b']]);
		expect(parseTSV('a\r\n\r\nb')).toEqual([['a'], [''], ['b']]);
	});

	it('returns an empty block for empty text', () => {
		expect(parseTSV('')).toEqual([]);
	});

	it('round-trips serializeTSV output', () => {
		const block = [
			['Acme Corp — Platform License', 'open', '120000'],
			['multi\nline', 'tab\there', 'say "hi"'],
			['', '2026-09-30 → 2026-12-21', '']
		];
		expect(parseTSV(serializeTSV(block))).toEqual(block);
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

	it('copies range cells as the two stored bounds joined with the arrow', () => {
		// A `period`'s bounds are the stored UTC instants — never converted.
		expect(
			cellCopyText(field('period'), { start: '2026-11-01T00:00:00Z', end: '2027-01-31T23:59:59Z' })
		).toBe('2026-11-01T00:00:00Z → 2027-01-31T23:59:59Z');
		// A `dateperiod`'s bounds are calendar dates, verbatim.
		expect(cellCopyText(field('dateperiod'), { start: '2026-12-01', end: '2026-12-21' })).toBe(
			'2026-12-01 → 2026-12-21'
		);
	});

	it('copies a half-set range as empty text', () => {
		expect(cellCopyText(field('period'), { start: '2026-11-01T00:00:00Z', end: null })).toBe('');
		expect(cellCopyText(field('dateperiod'), { start: '', end: '2026-12-21' })).toBe('');
		// A malformed value never yields `[object Object]`.
		expect(cellCopyText(field('period'), 'garbage')).toBe('garbage');
	});

	it('falls back to String for a field-less column', () => {
		expect(cellCopyText(null, 'text')).toBe('text');
		expect(cellCopyText(null, 42)).toBe('42');
	});
});
