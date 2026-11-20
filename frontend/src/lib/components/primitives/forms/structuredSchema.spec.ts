// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it } from 'vitest';
import { parseStructured } from './structuredSchema.js';
import type { FieldDef } from '$lib/doctype/types.js';

function field(partial: Partial<FieldDef>): FieldDef {
	return { key: 'payload', type: 'object', ...partial } as FieldDef;
}

describe('parseStructured', () => {
	it('parses blank text to the cleared sentinel', () => {
		expect(parseStructured('', field({}))).toEqual({ ok: true, value: '' });
		expect(parseStructured('   \n ', field({}))).toEqual({ ok: true, value: '' });
	});

	it('reports invalid JSON syntax', () => {
		const res = parseStructured('{ not json', field({}));
		expect(res).toEqual({ ok: false, reason: 'json' });
	});

	it('accepts a matching object and returns the parsed structure', () => {
		const def = field({
			type: 'object',
			properties: [
				{ key: 'street', type: 'string' },
				{ key: 'floors', type: 'integer' }
			]
		});
		const res = parseStructured('{"street":"Main St","floors":3}', def);
		expect(res).toEqual({ ok: true, value: { street: 'Main St', floors: 3 } });
	});

	it('rejects a scalar where an object is declared', () => {
		const res = parseStructured('"hello"', field({ type: 'object' }));
		expect(res).toMatchObject({ ok: false, reason: 'schema', issue: { expected: 'an object' } });
	});

	it('rejects a declared sub-field with the wrong type', () => {
		const def = field({
			type: 'object',
			properties: [{ key: 'floors', type: 'integer' }]
		});
		const res = parseStructured('{"floors":"three"}', def);
		expect(res).toMatchObject({
			ok: false,
			reason: 'schema',
			issue: { path: 'payload.floors', expected: 'a number' }
		});
	});

	it('passes through undeclared object keys unchecked', () => {
		const def = field({ type: 'object', properties: [{ key: 'a', type: 'string' }] });
		const res = parseStructured('{"a":"x","extra":{"nested":[1,2]}}', def);
		expect(res).toEqual({ ok: true, value: { a: 'x', extra: { nested: [1, 2] } } });
	});

	it('validates array items against the declared item schema', () => {
		const def = field({
			type: 'array',
			items: { key: '(items)', type: 'string' }
		});
		expect(parseStructured('["a","b"]', def)).toEqual({ ok: true, value: ['a', 'b'] });
		const bad = parseStructured('["a",42]', def);
		expect(bad).toMatchObject({
			ok: false,
			reason: 'schema',
			issue: { path: 'payload[1]', expected: 'a string' }
		});
	});

	it('rejects a non-array where an array is declared', () => {
		const res = parseStructured('{"a":1}', field({ type: 'array' }));
		expect(res).toMatchObject({ ok: false, reason: 'schema', issue: { expected: 'an array' } });
	});

	it('validates dictionary entries against the declared entry schema', () => {
		const def = field({
			type: 'dictionary',
			dictionaryValue: { key: '(value)', type: 'integer' }
		});
		expect(parseStructured('{"small":1,"large":99}', def)).toEqual({
			ok: true,
			value: { small: 1, large: 99 }
		});
		const bad = parseStructured('{"small":"one"}', def);
		expect(bad).toMatchObject({
			ok: false,
			reason: 'schema',
			issue: { path: 'payload.small', expected: 'a number' }
		});
	});

	it('accepts a dictionary without a declared entry schema', () => {
		const def = field({ type: 'dictionary' });
		expect(parseStructured('{"anything":{"goes":[true]}}', def)).toEqual({
			ok: true,
			value: { anything: { goes: [true] } }
		});
	});

	it('skips null sub-values (the backend treats null as unset)', () => {
		const def = field({
			type: 'object',
			properties: [{ key: 'floors', type: 'integer' }]
		});
		expect(parseStructured('{"floors":null}', def)).toEqual({
			ok: true,
			value: { floors: null }
		});
	});

	it('validates a nested money property shape', () => {
		const def = field({
			type: 'object',
			properties: [{ key: 'price', type: 'money' }]
		});
		expect(parseStructured('{"price":{"value":"9.99","currency":"EUR"}}', def)).toEqual({
			ok: true,
			value: { price: { value: '9.99', currency: 'EUR' } }
		});
		const bad = parseStructured('{"price":{"value":9.99,"currency":"EUR"}}', def);
		expect(bad).toMatchObject({
			ok: false,
			reason: 'schema',
			issue: { path: 'payload.price', expected: 'an object with value and currency' }
		});
	});
});
