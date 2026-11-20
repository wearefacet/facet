// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import {
	resolveValue,
	resolveInterpolated,
	resolveRaw,
	isReferenceField,
	fieldDefFor
} from './template-resolve';
import type { DoctypeDef } from './doctype/types.js';

describe('resolveValue', () => {
	it('returns literal text as-is when no $ prefix', () => {
		expect(resolveValue('Plain text', {})).toBe('Plain text');
	});

	it('resolves $field from document', () => {
		expect(resolveValue('$name', { name: 'Alice' })).toBe('Alice');
	});

	it('resolves nested path with dot notation', () => {
		expect(resolveValue('$contact.email', { contact: { email: 'a@b.com' } })).toBe('a@b.com');
	});

	it('returns the raw value string when field is missing', () => {
		expect(resolveValue('$missing', {})).toBe('$missing');
	});

	it('returns the raw value string when nested path is missing', () => {
		expect(resolveValue('$contact.missing', { contact: {} })).toBe('$contact.missing');
	});

	it('returns the raw value string when intermediate is null', () => {
		expect(resolveValue('$contact.email', { contact: null })).toBe('$contact.email');
	});

	it('coerces numbers to string', () => {
		expect(resolveValue('$age', { age: 42 })).toBe('42');
	});

	it('coerces boolean to string', () => {
		expect(resolveValue('$active', { active: true })).toBe('true');
	});

	it('formats a money object as "<currency> <value>"', () => {
		expect(resolveValue('$value', { value: { value: '120000', currency: 'EUR' } })).toBe(
			'EUR 120000'
		);
	});

	it('formats a money object with a numeric amount', () => {
		expect(resolveValue('$amount', { amount: { value: 2500, currency: 'USD' } })).toBe('USD 2500');
	});

	it('renders a secret marker as empty text', () => {
		expect(
			resolveValue('$api_key', {
				api_key: { mode: 'hash', version: 1, set_at: '2026-01-01T00:00:00Z' }
			})
		).toBe('');
	});

	it('renders a non-money object as JSON instead of [object Object]', () => {
		expect(resolveValue('$bag', { bag: { USD: '110.50' } })).toBe('{"USD":"110.50"}');
	});

	it('handles empty string', () => {
		expect(resolveValue('', {})).toBe('');
	});

	it('handles just a dollar sign', () => {
		expect(resolveValue('$', {})).toBe('$');
	});

	it('resolves a missing template value to empty text instead of throwing', () => {
		// A malformed, model-authored node (a `capsule` without `value`) must
		// degrade to empty text, not crash the render with `value.startsWith`.
		expect(resolveValue(undefined, {})).toBe('');
		expect(resolveValue(null, {})).toBe('');
	});

	it('coerces a non-string template value to text', () => {
		expect(resolveValue(42 as unknown as string, {})).toBe('42');
	});
});

describe('resolveInterpolated', () => {
	it('returns literal text as-is when no $ prefix', () => {
		expect(resolveInterpolated('Plain text', {})).toBe('Plain text');
	});

	it('resolves $field from document', () => {
		expect(resolveInterpolated('$name', { name: 'Alice' })).toBe('Alice');
	});

	it('resolves multiple fields with literal text', () => {
		expect(
			resolveInterpolated('$first_name $last_name', {
				first_name: 'Alice',
				last_name: 'Wonderland'
			})
		).toBe('Alice Wonderland');
	});

	it('returns empty string for a missing field instead of the raw $token', () => {
		expect(resolveInterpolated('$missing', {})).toBe('');
	});

	it('returns empty string for a missing nested path instead of the raw $token', () => {
		expect(resolveInterpolated('$contact.email', { contact: {} })).toBe('');
	});

	it('returns empty string when an intermediate is null', () => {
		expect(resolveInterpolated('$contact.email', { contact: null })).toBe('');
	});

	it('coerces numbers and booleans to string', () => {
		expect(resolveInterpolated('$age', { age: 42 })).toBe('42');
		expect(resolveInterpolated('$active', { active: true })).toBe('true');
	});

	it('formats a money object instead of printing [object Object]', () => {
		expect(resolveInterpolated('$value', { value: { value: '120000', currency: 'EUR' } })).toBe(
			'EUR 120000'
		);
	});

	it('formats money inside mixed literal text', () => {
		expect(
			resolveInterpolated('Total: $value', { value: { value: '120000', currency: 'EUR' } })
		).toBe('Total: EUR 120000');
	});

	it('renders a secret marker as empty instead of JSON', () => {
		expect(
			resolveInterpolated('$token', {
				token: { mode: 'token', version: 2, set_at: '2026-01-01T00:00:00Z' }
			})
		).toBe('');
	});

	it('renders a non-money object as JSON instead of [object Object]', () => {
		expect(resolveInterpolated('$bag', { bag: { USD: '110.50' } })).toBe('{"USD":"110.50"}');
	});

	it('resolves a missing template value to empty text instead of throwing', () => {
		// The crash class from the probing-assistant incident: a `capsule` node
		// without `value` hit `String.replace` on undefined and blanked the app
		// through the error boundary. A malformed node renders empty instead.
		expect(resolveInterpolated(undefined, {})).toBe('');
		expect(resolveInterpolated(null, {})).toBe('');
	});

	it('coerces a non-string template value to text', () => {
		expect(resolveInterpolated(42 as unknown as string, {})).toBe('42');
	});
});

describe('isReferenceField', () => {
	const def: DoctypeDef = {
		doctype: 'Activity',
		domain: 'crm',
		fields: [
			{ key: 'subject', type: 'string' },
			{ key: 'deal_id', type: 'reference', doctype: 'crm.Deal' },
			{ key: 'ref_without_target', type: 'reference' }
		],
		children: [],
		actions: []
	};

	it('matches a single $field token whose declared type is reference', () => {
		expect(isReferenceField('$deal_id', def)).toEqual({
			fieldKey: 'deal_id',
			qualifiedDoctype: 'crm.Deal'
		});
	});

	it('returns null for an interpolated string', () => {
		expect(isReferenceField('$first_name $last_name', def)).toBeNull();
	});

	it('returns null for a literal', () => {
		expect(isReferenceField('just text', def)).toBeNull();
	});

	it('returns null for a $field that is not declared as reference', () => {
		expect(isReferenceField('$subject', def)).toBeNull();
	});

	it('returns null when the reference has no target doctype', () => {
		expect(isReferenceField('$ref_without_target', def)).toBeNull();
	});

	it('returns null when no doctype definition is provided', () => {
		expect(isReferenceField('$deal_id', undefined)).toBeNull();
	});
});

describe('fieldDefFor', () => {
	const def: DoctypeDef = {
		doctype: 'Activity',
		domain: 'crm',
		fields: [
			{ key: 'subject', type: 'string' },
			{ key: 'amount', type: 'money', currency: 'USD' },
			{ key: 'due_at', type: 'datetime' },
			{ key: 'status', type: 'enum', values: [{ key: 'open' }, { key: 'closed' }] },
			{ key: 'color', type: 'color' },
			{ key: 'active', type: 'boolean' }
		],
		children: [],
		actions: []
	};

	it('finds a field by key', () => {
		const f = fieldDefFor(def, 'subject');
		expect(f).not.toBeNull();
		expect(f!.type).toBe('string');
	});

	it('finds a field with $ prefix', () => {
		const f = fieldDefFor(def, '$amount');
		expect(f).not.toBeNull();
		expect(f!.type).toBe('money');
		expect(f!.currency).toBe('USD');
	});

	it('returns null for unknown field', () => {
		expect(fieldDefFor(def, 'missing')).toBeNull();
	});

	it('returns null when def is undefined', () => {
		expect(fieldDefFor(undefined, 'subject')).toBeNull();
	});

	it('finds field of type color', () => {
		const f = fieldDefFor(def, 'color');
		expect(f).not.toBeNull();
		expect(f!.type).toBe('color');
	});

	it('finds field of type enum', () => {
		const f = fieldDefFor(def, 'status');
		expect(f).not.toBeNull();
		expect(f!.type).toBe('enum');
		expect(f!.values).toEqual([{ key: 'open' }, { key: 'closed' }]);
	});
});

describe('resolveRaw', () => {
	it('returns the raw value for a field key or $field token', () => {
		expect(resolveRaw('contact', { contact: { email: 'a@b.com' } })).toEqual({ email: 'a@b.com' });
		expect(resolveRaw('$contact', { contact: { email: 'a@b.com' } })).toEqual({
			email: 'a@b.com'
		});
	});

	it('returns undefined for a missing field', () => {
		expect(resolveRaw('missing', {})).toBeUndefined();
	});

	it('returns undefined for a missing or non-string template field', () => {
		// A malformed, model-authored node (an `object` without `field`) must
		// resolve to "cannot resolve", not crash on `field.startsWith`.
		expect(resolveRaw(undefined, { contact: { email: 'a@b.com' } })).toBeUndefined();
		expect(resolveRaw(null, {})).toBeUndefined();
	});
});
