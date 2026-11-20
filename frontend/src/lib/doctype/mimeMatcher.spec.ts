// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it } from 'vitest';
import { isValidMimePattern, matchesMime } from './mimeMatcher.js';

describe('mimeMatcher', () => {
	describe('isValidMimePattern', () => {
		it('accepts concrete and wildcard subtypes', () => {
			expect(isValidMimePattern('image/png')).toBe(true);
			expect(isValidMimePattern('application/pdf')).toBe(true);
			expect(isValidMimePattern('image/*')).toBe(true);
		});

		it('rejects malformed tokens', () => {
			expect(isValidMimePattern('image')).toBe(false);
			expect(isValidMimePattern('*/*')).toBe(false);
			expect(isValidMimePattern('*/png')).toBe(false);
			expect(isValidMimePattern('image/png ')).toBe(false);
		});
	});

	describe('matchesMime', () => {
		it('matches concrete and wildcard patterns', () => {
			expect(matchesMime('image/png', ['image/*'])).toBe(true);
			expect(matchesMime('image/png', ['image/png'])).toBe(true);
			expect(matchesMime('application/pdf', ['application/pdf'])).toBe(true);
			expect(matchesMime('application/pdf', ['image/*', 'application/pdf'])).toBe(true);
		});

		it('does not match across types or unknown subtypes', () => {
			expect(matchesMime('application/pdf', ['image/*'])).toBe(false);
			expect(matchesMime('image/png', ['image/jpeg'])).toBe(false);
			expect(matchesMime('image/png', ['application/*'])).toBe(false);
		});
	});
});
