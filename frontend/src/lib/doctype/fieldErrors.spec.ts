// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { buildFormError, groupFieldErrors, joinFieldErrors } from './fieldErrors.js';
import type { ValidationError } from '$lib/datasource/types';

describe('groupFieldErrors', () => {
	it('returns empty buckets for null input', () => {
		expect(groupFieldErrors(null)).toEqual({ fieldErrors: {}, general: [] });
	});

	it('returns empty buckets for undefined input', () => {
		expect(groupFieldErrors(undefined)).toEqual({ fieldErrors: {}, general: [] });
	});

	it('returns empty buckets for an empty array', () => {
		expect(groupFieldErrors([])).toEqual({ fieldErrors: {}, general: [] });
	});

	it('groups a single field-scoped error under its top-level segment', () => {
		const d: ValidationError = { field: 'subject', message: 'is missing', code: 'required' };
		const out = groupFieldErrors([d]);
		expect(out.general).toEqual([]);
		expect(out.fieldErrors).toEqual({ subject: [d] });
	});

	it('groups nested dotted paths under the leading segment, preserving the full error', () => {
		const a: ValidationError = {
			field: 'period.start',
			message: 'must be a string',
			code: 'invalid_type'
		};
		const b: ValidationError = {
			field: 'period.end',
			message: 'cannot be null',
			code: 'invalid_type'
		};
		const out = groupFieldErrors([a, b]);
		expect(out.fieldErrors).toEqual({ period: [a, b] });
		expect(out.general).toEqual([]);
	});

	it('bins null/undefined field errors into general (script/rbac/compute/schema)', () => {
		const noField: ValidationError = { message: 'script error', code: 'script' };
		const nullField: ValidationError = { field: null, message: 'rbac denied', code: 'rbac' };
		const undefinedField: ValidationError = {
			field: undefined,
			message: 'compute failed',
			code: 'compute'
		};
		const out = groupFieldErrors([noField, nullField, undefinedField]);
		expect(out.fieldErrors).toEqual({});
		expect(out.general).toEqual([noField, nullField, undefinedField]);
	});

	it('handles a mixed payload (field + nested + general) and attributes each correctly', () => {
		const subject: ValidationError = { field: 'subject', message: 'is missing', code: 'required' };
		const assigned: ValidationError = {
			field: 'assigned_to',
			message: 'is missing',
			code: 'required'
		};
		const periodStart: ValidationError = {
			field: 'period.start',
			message: 'must be a string (ISO 8601 datetime)',
			code: 'invalid_type'
		};
		const script: ValidationError = { message: 'title cannot be bad', code: 'script' };
		const itemsName: ValidationError = {
			field: 'items.3.name',
			message: 'is missing',
			code: 'required'
		};

		const out = groupFieldErrors([subject, assigned, periodStart, script, itemsName]);

		expect(out.general).toEqual([script]);
		expect(Object.keys(out.fieldErrors).sort()).toEqual([
			'assigned_to',
			'items',
			'period',
			'subject'
		]);
		expect(out.fieldErrors.subject).toEqual([subject]);
		expect(out.fieldErrors.assigned_to).toEqual([assigned]);
		expect(out.fieldErrors.period).toEqual([periodStart]);
		expect(out.fieldErrors.items).toEqual([itemsName]);
	});

	it('keeps multiple errors for the same top-level field in order', () => {
		const a: ValidationError = { field: 'subject', message: 'is missing', code: 'required' };
		const b: ValidationError = { field: 'subject', message: 'too short', code: 'invalid_format' };
		const out = groupFieldErrors([a, b]);
		expect(out.fieldErrors.subject).toEqual([a, b]);
	});
});

describe('joinFieldErrors', () => {
	it('returns undefined when the map is null/undefined or has no entry for the key', () => {
		expect(joinFieldErrors(null, 'subject')).toBeUndefined();
		expect(joinFieldErrors(undefined, 'subject')).toBeUndefined();
		expect(joinFieldErrors({}, 'subject')).toBeUndefined();
	});

	it('returns undefined for an empty list (should not occur in practice)', () => {
		expect(joinFieldErrors({ subject: [] }, 'subject')).toBeUndefined();
	});

	it('returns the single rendered message when only one error is present', () => {
		const map = { subject: [{ field: 'subject', message: 'is missing', code: 'required' }] };
		expect(joinFieldErrors(map, 'subject')).toBe('This field is required.');
	});

	it('joins multiple rendered messages with the middle-dot separator', () => {
		const map = {
			subject: [
				{ field: 'subject', message: 'is missing', code: 'required' },
				{ field: 'subject', message: 'too short', code: 'invalid_format' }
			]
		};
		expect(joinFieldErrors(map, 'subject')).toBe('This field is required. · too short');
	});

	it('renders templated codes with params through the catalogue', () => {
		const map = {
			status: [
				{
					field: 'status',
					message: "has invalid enum value 'archived' (allowed: active)",
					code: 'invalid_format',
					params: { value: 'archived', allowed: 'active', format: 'one of: active' }
				}
			]
		};
		expect(joinFieldErrors(map, 'status')).toBe(
			'This value has an invalid format: one of: active.'
		);
	});

	it('falls back to the pasted message for codes without a template', () => {
		const map = {
			title: [{ message: 'title cannot be bad', code: 'script' }]
		};
		expect(joinFieldErrors(map, 'title')).toBe('title cannot be bad');
	});

	it('looks up by top-level segment even when nested errors were grouped under it', () => {
		const map = {
			period: [
				{ field: 'period.start', message: 'must be a string', code: 'invalid_type' },
				{ field: 'period.end', message: 'cannot be null', code: 'invalid_type' }
			]
		};
		// `invalid_type` without an `expected` param falls back to the pasted
		// backend message — the template only renders when its params are present.
		expect(joinFieldErrors(map, 'period')).toBe('must be a string · cannot be null');
	});
});

describe('buildFormError', () => {
	it('returns the headline alone when there are no details', () => {
		expect(buildFormError('Script validation failed', groupFieldErrors([]))).toEqual({
			message: 'Script validation failed',
			details: []
		});
	});

	it('renders field-less details under the headline', () => {
		const grouped = groupFieldErrors([
			{ field: null, message: 'issuer must be an absolute https URL', code: null }
		]);
		expect(buildFormError('Script validation failed', grouped)).toEqual({
			message: 'Script validation failed',
			details: ['issuer must be an absolute https URL']
		});
	});

	it('stays quiet when only field-scoped errors exist', () => {
		const grouped = groupFieldErrors([
			{ field: 'issuer', message: 'must be an absolute https URL', code: 'invalid_format' }
		]);
		expect(buildFormError('Document validation failed', grouped)).toBeUndefined();
	});

	it('renders field-less details beside field-scoped errors', () => {
		const grouped = groupFieldErrors([
			{ field: 'issuer', message: 'must be an absolute https URL', code: 'invalid_format' },
			{ field: null, message: 'script failed', code: 'script' }
		]);
		expect(buildFormError('Document validation failed', grouped)).toEqual({
			message: 'Document validation failed',
			details: ['script failed']
		});
	});
});
