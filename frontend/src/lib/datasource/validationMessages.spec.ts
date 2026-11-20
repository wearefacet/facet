// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { renderValidationError } from './validationMessages.js';
import type { ValidationError } from './types.js';

describe('renderValidationError', () => {
	describe('templated codes with params', () => {
		it('renders invalid_type from the expected param', () => {
			const e: ValidationError = {
				field: 'subject',
				message: 'must be a string (ISO 8601 datetime)',
				code: 'invalid_type',
				params: { expected: 'a string (ISO 8601 datetime)' }
			};
			expect(renderValidationError(e)).toBe(
				'This value has the wrong type — expected a string (ISO 8601 datetime).'
			);
		});

		it('renders invalid_format from the format param', () => {
			const e: ValidationError = {
				field: 'start',
				message: "is not a valid ISO 8601 date (expected YYYY-MM-DD): '2026-13-45'",
				code: 'invalid_format',
				params: { value: '2026-13-45', format: 'an ISO 8601 date (YYYY-MM-DD)' }
			};
			expect(renderValidationError(e)).toBe(
				'This value has an invalid format: an ISO 8601 date (YYYY-MM-DD).'
			);
		});

		it('renders out_of_range from the reason param', () => {
			const e: ValidationError = {
				field: 'period',
				message: "start must be strictly before end (period bounds are '[)' — exclusive upper)",
				code: 'out_of_range',
				params: { reason: 'start must be strictly before end' }
			};
			expect(renderValidationError(e)).toBe(
				'This value is out of range: start must be strictly before end.'
			);
		});

		it('renders too_long from the max param', () => {
			const e: ValidationError = {
				field: 'status.values.archived',
				message: "enum key 'archived' exceeds max length of 64 characters",
				code: 'too_long',
				params: { value: 'archived', max: '64' }
			};
			expect(renderValidationError(e)).toBe(
				'This value is too long — the maximum length is 64 characters.'
			);
		});

		it('renders inactive_currency from the value param', () => {
			const e: ValidationError = {
				field: 'amount.currency',
				message: "must be an active currency (got 'XYZ', which is inactive)",
				code: 'inactive_currency',
				params: { value: 'XYZ' }
			};
			expect(renderValidationError(e)).toBe('The currency XYZ is inactive and cannot be used.');
		});

		it('renders reference_target_not_found from the value param', () => {
			const e: ValidationError = {
				field: 'company',
				message: "referenced doctype 'crm.Company' is not a registered doctype",
				code: 'reference_target_not_found',
				params: { value: 'crm.Company' }
			};
			expect(renderValidationError(e)).toBe('The referenced doctype crm.Company does not exist.');
		});
	});

	describe('templated codes without params', () => {
		it('renders required, read_only, reserved, and unknown_field with no params', () => {
			expect(
				renderValidationError({ field: 'subject', message: 'is missing', code: 'required' })
			).toBe('This field is required.');
			expect(
				renderValidationError({
					field: 'subject',
					message: 'is read-only and should not be set',
					code: 'read_only'
				})
			).toBe('This field is read-only and cannot be set.');
			expect(
				renderValidationError({
					field: 'parent_id',
					message: 'is a system-reserved field and cannot be set',
					code: 'reserved'
				})
			).toBe('This field name is reserved and cannot be used.');
			expect(
				renderValidationError({
					field: 'set',
					message: 'is not a defined field',
					code: 'unknown_field'
				})
			).toBe('This field is not defined on the doctype.');
		});

		it('renders invalid_reference_format with no params', () => {
			expect(
				renderValidationError({
					field: 'company',
					message: "must be a fully qualified reference id of the form '{domain}.{Doctype}.{id}'",
					code: 'invalid_reference_format'
				})
			).toBe('This reference value must use the domain.Doctype.id form.');
		});

		it('renders unique with no params (the stamped value stays unused)', () => {
			expect(
				renderValidationError({
					field: 'email',
					message: "must be unique, but value 'a@b.c' already exists",
					code: 'unique',
					params: { value: 'a@b.c' }
				})
			).toBe('This value is already in use.');
		});
	});

	describe('fallback to the pasted message', () => {
		it('falls back when a param-hungry template has no params', () => {
			const e: ValidationError = {
				field: 'subject',
				message: 'too short',
				code: 'invalid_format'
			};
			expect(renderValidationError(e)).toBe('too short');
		});

		it('falls back for codes without a template (script, schema, compute, rbac)', () => {
			const codes = ['script', 'schema', 'compute', 'compute_runtime', 'rbac', 'argument'];
			for (const code of codes) {
				const e: ValidationError = { message: `raw ${code} text`, code };
				expect(renderValidationError(e)).toBe(`raw ${code} text`);
			}
		});

		it('falls back when the code is missing or null', () => {
			expect(renderValidationError({ message: 'no code here' })).toBe('no code here');
			expect(renderValidationError({ field: null, message: 'null code', code: null })).toBe(
				'null code'
			);
		});

		it('falls back to the message for an unknown forward-compat code', () => {
			const e: ValidationError = { message: 'future wording', code: 'some_new_code' };
			expect(renderValidationError(e)).toBe('future wording');
		});
	});
});
