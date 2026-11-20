// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { hashColor } from './color.js';

describe('hashColor', () => {
	it('returns a 7-character hex string', () => {
		const c = hashColor('hr.Candidate');
		expect(c).toMatch(/^#[0-9A-Fa-f]{6}$/);
	});

	it('is stable for the same seed', () => {
		expect(hashColor('crm.Deal')).toBe(hashColor('crm.Deal'));
	});

	it('differs for different seeds', () => {
		const a = hashColor('hr.Candidate');
		const b = hashColor('crm.Deal');
		expect(a).not.toBe(b);
	});

	it('is empty-seed safe (does not throw)', () => {
		expect(() => hashColor('')).not.toThrow();
		expect(hashColor('')).toMatch(/^#[0-9A-Fa-f]{6}$/);
	});

	it('produces different hues across many seeds', () => {
		const seeds = ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h'];
		const colors = new Set(seeds.map(hashColor));
		// At least 6 of 8 distinct — confirms the hash spreads hues.
		expect(colors.size).toBeGreaterThanOrEqual(6);
	});
});
