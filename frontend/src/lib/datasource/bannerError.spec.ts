// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { toBannerError } from './bannerError.js';
import { DataSourceError, type ValidationError } from './types.js';

describe('toBannerError', () => {
	it('returns the message with no detail lines for a plain Error', () => {
		expect(toBannerError(new Error('boom'))).toEqual({ message: 'boom', details: [] });
	});

	it('returns the stringified value for a non-Error thrown value', () => {
		expect(toBannerError('nope')).toEqual({ message: 'nope', details: [] });
	});

	it('returns the headline and no details when the DataSourceError has no details', () => {
		const err = new DataSourceError(422, 'Document validation failed');
		expect(toBannerError(err)).toEqual({ message: 'Document validation failed', details: [] });
	});

	it('prefixed each field-scoped detail with the field path', () => {
		const details: ValidationError[] = [
			{ field: 'set', message: 'is not a defined field', code: 'unknown_field' }
		];
		const err = new DataSourceError(422, 'Document validation failed', details);
		expect(toBannerError(err)).toEqual({
			message: 'Document validation failed',
			details: ['set — This field is not defined on the doctype.']
		});
	});

	it('renders field-scoped details with params through the catalogue', () => {
		const details: ValidationError[] = [
			{
				field: 'status',
				message: "has invalid enum value 'archived' (allowed: active)",
				code: 'invalid_format',
				params: { value: 'archived', allowed: 'active', format: 'one of: active' }
			}
		];
		const err = new DataSourceError(422, 'Document validation failed', details);
		expect(toBannerError(err)).toEqual({
			message: 'Document validation failed',
			details: ['status — This value has an invalid format: one of: active.']
		});
	});

	it('falls back to the pasted message for codes without a template', () => {
		const details: ValidationError[] = [
			{ field: null, message: 'hire_date cannot be in the future', code: 'script' }
		];
		const err = new DataSourceError(422, 'Script validation failed', details);
		expect(toBannerError(err)).toEqual({
			message: 'Script validation failed',
			details: ['hire_date cannot be in the future']
		});
	});

	it('keeps multiple detail lines in order', () => {
		const details: ValidationError[] = [
			{ field: 'name', message: 'is missing', code: 'required' },
			{ field: 'set', message: 'is not a defined field', code: 'unknown_field' },
			{ message: 'unrelated failure', code: 'schema' }
		];
		const err = new DataSourceError(422, 'Document validation failed', details);
		expect(toBannerError(err).details).toEqual([
			'name — This field is required.',
			'set — This field is not defined on the doctype.',
			'unrelated failure'
		]);
	});
});
