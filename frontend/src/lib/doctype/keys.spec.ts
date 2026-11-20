// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { sanitizeKeyInput, nextUniqueKey } from './keys.js';

describe('keys — editor key helpers', () => {
	describe('sanitizeKeyInput', () => {
		it('lowercases and strips characters outside [a-z0-9_]', () => {
			expect(sanitizeKeyInput('Deal Amount')).toBe('dealamount');
			expect(sanitizeKeyInput('Foo-Bar!')).toBe('foobar');
			expect(sanitizeKeyInput('Ünïcode')).toBe('ncode');
		});

		it('strips leading non-letters so the key starts with a letter', () => {
			expect(sanitizeKeyInput('1abc')).toBe('abc');
			expect(sanitizeKeyInput('_x')).toBe('x');
			expect(sanitizeKeyInput('9_8')).toBe('');
		});

		it('keeps a leading letter and interior underscores/digits', () => {
			expect(sanitizeKeyInput('A_b2')).toBe('a_b2');
		});

		it('returns an empty string for empty or fully stripped input', () => {
			expect(sanitizeKeyInput('')).toBe('');
			expect(sanitizeKeyInput('***')).toBe('');
			expect(sanitizeKeyInput('123')).toBe('');
		});
	});

	describe('nextUniqueKey', () => {
		it('returns the base when it is free', () => {
			expect(nextUniqueKey(['other'], 'new_field')).toBe('new_field');
			expect(nextUniqueKey([], 'new_field')).toBe('new_field');
		});

		it('suffixes _1 when the base is taken', () => {
			expect(nextUniqueKey(['new_field'], 'new_field')).toBe('new_field_1');
		});

		it('walks past existing suffixes without gaps', () => {
			expect(nextUniqueKey(['new_field', 'new_field_1', 'new_field_2'], 'new_field')).toBe(
				'new_field_3'
			);
		});

		it('ignores keys that only share a prefix', () => {
			expect(nextUniqueKey(['new_field_10'], 'new_field')).toBe('new_field');
		});

		it('accepts any iterable of keys', () => {
			expect(nextUniqueKey(new Set(['a']), 'a')).toBe('a_1');
		});
	});
});
