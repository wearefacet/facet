// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it } from 'vitest';
import { decodeLoginError, LoginRejected } from './loginFlow';

/**
 * B-139 — the password path surfaces the brute-force counter on the 401
 * (`meta.remaining_attempts`), the same signal the MFA challenge path puts
 * in its message. The decoder maps the error body to a `LoginRejected`
 * whose `remainingAttempts` the login form renders as the inline warning.
 */
describe('decodeLoginError', () => {
	it('carries the backend message and the remaining count', () => {
		const err = decodeLoginError(
			{ error: 'Invalid credentials', remaining_attempts: '9' },
			'fallback'
		);
		expect(err).toBeInstanceOf(LoginRejected);
		expect(err.message).toBe('Invalid credentials');
		expect(err.remainingAttempts).toBe(9);
	});

	it('accepts a numeric count', () => {
		const err = decodeLoginError(
			{ error: 'Invalid credentials', remaining_attempts: 3 },
			'fallback'
		);
		expect(err.remainingAttempts).toBe(3);
	});

	it('reads null when the backend sends no count', () => {
		const err = decodeLoginError({ error: 'Invalid credentials' }, 'fallback');
		expect(err.remainingAttempts).toBeNull();
	});

	it('reads null on a non-numeric count', () => {
		const err = decodeLoginError(
			{ error: 'Invalid credentials', remaining_attempts: 'many' },
			'fallback'
		);
		expect(err.remainingAttempts).toBeNull();
	});

	it('falls back to the catalogue message when the body has no error field', () => {
		const err = decodeLoginError({}, 'Login failed');
		expect(err.message).toBe('Login failed');
		expect(err.remainingAttempts).toBeNull();
	});

	it('survives a non-object body', () => {
		const err = decodeLoginError(null, 'Login failed');
		expect(err.message).toBe('Login failed');
	});
});
