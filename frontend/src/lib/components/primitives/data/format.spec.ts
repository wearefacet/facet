// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { composeMoneyText, formatMoneyAmount } from './format.js';

describe('formatMoneyAmount', () => {
	it('formats with 2 digits by default (standard grouping)', () => {
		expect(formatMoneyAmount(12480)).toBe('12,480.00');
	});

	it('formats 0 digits as whole units', () => {
		expect(formatMoneyAmount(15499.5, { digits: 0 })).toBe('15,500');
	});

	it('formats 3 digits (millis)', () => {
		expect(formatMoneyAmount(1.2, { digits: 3 })).toBe('1.200');
	});

	it('formats negative and decimal values', () => {
		expect(formatMoneyAmount(-1234.5)).toBe('-1,234.50');
		expect(formatMoneyAmount(-50)).toBe('-50.00');
		expect(formatMoneyAmount(0.105)).toBe('0.11'); // display rounding only
	});

	it('formats zero', () => {
		expect(formatMoneyAmount(0)).toBe('0.00');
		expect(formatMoneyAmount(0, { digits: 0 })).toBe('0');
	});

	it('groups the Indian way under the lakhs style', () => {
		expect(formatMoneyAmount(1234567, { grouping: 'lakhs' })).toBe('12,34,567.00');
		expect(formatMoneyAmount(123456789, { grouping: 'lakhs', digits: 0 })).toBe('12,34,56,789');
	});

	it('keeps thousands grouping under the standard style', () => {
		expect(formatMoneyAmount(1234567, { grouping: 'standard' })).toBe('1,234,567.00');
	});

	it('falls back to 2 digits on a negative or non-integer digit count', () => {
		expect(formatMoneyAmount(5, { digits: -1 })).toBe('5.00');
		expect(formatMoneyAmount(5, { digits: 1.5 })).toBe('5.00');
	});
});

describe('composeMoneyText', () => {
	it('prefixes the symbol with one space', () => {
		expect(composeMoneyText('€', '1,234.50')).toBe('€ 1,234.50');
	});

	it('yields the bare amount when the label is empty', () => {
		expect(composeMoneyText('', '1,234.50')).toBe('1,234.50');
	});
});
