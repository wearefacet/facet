// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it } from 'vitest';
import { DECIMAL_RE, caretAfterFormat, formatAmount } from './moneyFormat.js';

describe('formatAmount', () => {
	it('returns the empty string for empty input', () => {
		expect(formatAmount('')).toBe('');
	});

	it('leaves short integers ungrouped', () => {
		expect(formatAmount('0')).toBe('0');
		expect(formatAmount('123')).toBe('123');
		expect(formatAmount('007')).toBe('007');
	});

	it("groups the integer part with ' every three digits from the right", () => {
		expect(formatAmount('1234')).toBe("1'234");
		expect(formatAmount('1234567')).toBe("1'234'567");
		expect(formatAmount('12345678')).toBe("12'345'678");
		expect(formatAmount('999999999')).toBe("999'999'999");
	});

	it('groups the integer part and keeps the fraction verbatim', () => {
		expect(formatAmount('1234567.89')).toBe("1'234'567.89");
		expect(formatAmount('1234.5')).toBe("1'234.5");
		expect(formatAmount('0.00')).toBe('0.00');
	});

	it('keeps the sign outside the groups', () => {
		expect(formatAmount('-1234')).toBe("-1'234");
		expect(formatAmount('-1234.56')).toBe("-1'234.56");
		expect(formatAmount('-0.5')).toBe('-0.5');
	});

	it('passes a trailing decimal point through ungrouped', () => {
		expect(formatAmount('12.')).toBe('12.');
		expect(formatAmount('1234.')).toBe('1234.');
	});

	it('returns non-decimal text unchanged (typeahead queries)', () => {
		expect(formatAmount('EUR')).toBe('EUR');
		expect(formatAmount('e')).toBe('e');
		expect(formatAmount('1e3')).toBe('1e3');
		expect(formatAmount('1 234')).toBe('1 234');
	});
});

describe('DECIMAL_RE', () => {
	it('accepts the canonical decimal shape', () => {
		expect(DECIMAL_RE.test('0')).toBe(true);
		expect(DECIMAL_RE.test('123')).toBe(true);
		expect(DECIMAL_RE.test('-42')).toBe(true);
		expect(DECIMAL_RE.test('12.5')).toBe(true);
		expect(DECIMAL_RE.test('-0.5')).toBe(true);
	});

	it('rejects every other shape', () => {
		expect(DECIMAL_RE.test('')).toBe(false);
		expect(DECIMAL_RE.test('12.')).toBe(false);
		expect(DECIMAL_RE.test('.5')).toBe(false);
		expect(DECIMAL_RE.test('+5')).toBe(false);
		expect(DECIMAL_RE.test('1,5')).toBe(false);
		expect(DECIMAL_RE.test('1e3')).toBe(false);
		expect(DECIMAL_RE.test('12.5.6')).toBe(false);
		expect(DECIMAL_RE.test(' 5')).toBe(false);
		expect(DECIMAL_RE.test('5 ')).toBe(false);
	});
});

describe('caretAfterFormat', () => {
	it('keeps the caret in place when no separator joins or leaves', () => {
		expect(caretAfterFormat('123', 2, '123')).toBe(2);
		expect(caretAfterFormat('eur', 2, 'eur')).toBe(2);
	});

	it('puts the caret at the start when it was at the start', () => {
		expect(caretAfterFormat("1'234", 0, "1'234")).toBe(0);
	});

	it('moves the caret past a separator the grouping inserted', () => {
		// Typed '9' at the end of '123' — the display regrouped under the caret.
		expect(caretAfterFormat('123', 3, "1'234")).toBe(4);
		expect(caretAfterFormat('1234', 2, "1'234")).toBe(3);
		expect(caretAfterFormat('1234567', 4, "1'234'567")).toBe(5);
	});

	it('counts the sign as a significant character', () => {
		// The sign is significant (it is not the separator): a caret after
		// '-1234' maps past the regrouped "-1'234" minus the inserted
		// separator — 5 significant chars → index 6.
		expect(caretAfterFormat('-1234', 5, "-1'234")).toBe(6);
	});

	it('lands at the end when the new text is shorter', () => {
		expect(caretAfterFormat('1234', 4, '123')).toBe(3);
		expect(caretAfterFormat('123', 2, '')).toBe(0);
	});

	it('keeps a mid-string edit before the inserted separator', () => {
		// Caret after '123' in '12345'; typing '9' there gives '123945'.
		expect(caretAfterFormat('12345', 3, "123'945")).toBe(3);
	});

	it('snaps to before a separator when the caret sat right after one', () => {
		// One significant char left of the caret — the earliest match is before "'".
		expect(caretAfterFormat("1'234", 2, "1'234")).toBe(1);
	});
});
