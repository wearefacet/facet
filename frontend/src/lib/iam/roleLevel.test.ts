// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it } from 'vitest';
import { levelToInput, parseLevelInput } from './roleLevel.js';

describe('parseLevelInput', () => {
	it('accepts whole numbers in range, with surrounding blanks', () => {
		expect(parseLevelInput('50')).toBe(50);
		expect(parseLevelInput(' 42 ')).toBe(42);
		expect(parseLevelInput('0')).toBe(0);
		expect(parseLevelInput('100')).toBe(100);
	});

	it('rejects an empty input (the field is required)', () => {
		expect(parseLevelInput('')).toBeNull();
		expect(parseLevelInput('   ')).toBeNull();
	});

	it('rejects negative, fractional, and non-digit input', () => {
		expect(parseLevelInput('-5')).toBeNull();
		expect(parseLevelInput('12.5')).toBeNull();
		expect(parseLevelInput('1e2')).toBeNull();
		expect(parseLevelInput('12a')).toBeNull();
	});

	it('rejects values outside the 0–100 range', () => {
		expect(parseLevelInput('101')).toBeNull();
		expect(parseLevelInput('999999999999999999999')).toBeNull();
	});
});

describe('levelToInput', () => {
	it('maps null and undefined to the empty string', () => {
		expect(levelToInput(null)).toBe('');
		expect(levelToInput(undefined)).toBe('');
	});

	it('formats a set level as its decimal string', () => {
		expect(levelToInput(50)).toBe('50');
		expect(levelToInput(0)).toBe('0');
	});
});

describe('round-trip', () => {
	it('round-trips a set level through the input and back', () => {
		const level = 75;
		expect(parseLevelInput(levelToInput(level))).toBe(level);
	});
});
