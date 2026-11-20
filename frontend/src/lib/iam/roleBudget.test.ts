// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it } from 'vitest';
import { budgetInputToValue, budgetInputValid, budgetToInput } from './roleBudget.js';

describe('budgetToInput', () => {
	it('maps null and undefined to the empty string', () => {
		expect(budgetToInput(null)).toBe('');
		expect(budgetToInput(undefined)).toBe('');
	});

	it('formats a set budget as its decimal string', () => {
		expect(budgetToInput(500000)).toBe('500000');
		expect(budgetToInput(0)).toBe('0');
	});
});

describe('budgetInputValid', () => {
	it('accepts any input while Unlimited is checked', () => {
		expect(budgetInputValid(true, '')).toBe(true);
		expect(budgetInputValid(true, 'abc')).toBe(true);
	});

	it('accepts digits (with surrounding blanks) when unchecked', () => {
		expect(budgetInputValid(false, '500000')).toBe(true);
		expect(budgetInputValid(false, ' 42 ')).toBe(true);
	});

	it('rejects an empty input when unchecked', () => {
		expect(budgetInputValid(false, '')).toBe(false);
		expect(budgetInputValid(false, '   ')).toBe(false);
	});

	it('rejects negative, fractional, and non-digit input when unchecked', () => {
		expect(budgetInputValid(false, '-5')).toBe(false);
		expect(budgetInputValid(false, '12.5')).toBe(false);
		expect(budgetInputValid(false, '1e3')).toBe(false);
		expect(budgetInputValid(false, '12a')).toBe(false);
	});
});

describe('budgetInputToValue', () => {
	it('maps a checked Unlimited box to an explicit null', () => {
		expect(budgetInputToValue(true, '')).toBeNull();
		expect(budgetInputToValue(true, '500')).toBeNull();
	});

	it('maps an unchecked valid input to its number', () => {
		expect(budgetInputToValue(false, '500000')).toBe(500000);
		expect(budgetInputToValue(false, ' 42 ')).toBe(42);
		expect(budgetInputToValue(false, '0')).toBe(0);
	});

	it('maps an unchecked invalid input to null (callers must validate first)', () => {
		expect(budgetInputToValue(false, '')).toBeNull();
		expect(budgetInputToValue(false, '-5')).toBeNull();
	});

	it('round-trips a set budget through the input and back', () => {
		const budget = 750000;
		expect(budgetInputToValue(false, budgetToInput(budget))).toBe(budget);
	});
});
