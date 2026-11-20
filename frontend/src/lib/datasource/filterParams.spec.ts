// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';

import { deserializeFilterValue, parseFilterParams, serializeFilterValue } from './filterParams.js';

/**
 * Unit tests for the `filters[...]` wire form.
 *
 * `serializeFilterValue` is the outbound writer every DataSource client uses;
 * `deserializeFilterValue` / `parseFilterParams` are the inbound mirror that
 * turns a shareable `filters[key__op]=value` deep link back into the
 * DataSource filter map (B-376).
 */

describe('serializeFilterValue', () => {
	it('keeps scalar values as their string form', () => {
		expect(serializeFilterValue('active')).toBe('active');
		expect(serializeFilterValue(18)).toBe('18');
		expect(serializeFilterValue(true)).toBe('true');
		expect(serializeFilterValue(null)).toBe('null');
		expect(serializeFilterValue(undefined)).toBe('undefined');
	});

	it('JSON-encodes arrays so they survive the query string', () => {
		expect(serializeFilterValue(['USD 25000', 'USD 100000'])).toBe('["USD 25000","USD 100000"]');
		expect(serializeFilterValue([100, 5000])).toBe('[100,5000]');
		expect(serializeFilterValue([])).toBe('[]');
	});

	it('does not comma-flatten arrays (the historical bug)', () => {
		// `String(['a', 'b'])` produced `a,b` — no backend operator parses
		// that, and a `__between` lane silently matched nothing.
		expect(serializeFilterValue(['a', 'b'])).not.toBe('a,b');
	});
});

describe('deserializeFilterValue', () => {
	it('keeps a scalar in its raw string form', () => {
		expect(deserializeFilterValue('tools')).toBe('tools');
		expect(deserializeFilterValue('5')).toBe('5');
		expect(deserializeFilterValue('')).toBe('');
	});

	it('decodes a JSON array back into a real array', () => {
		expect(deserializeFilterValue('["open","new"]')).toEqual(['open', 'new']);
		expect(deserializeFilterValue('[10, 20]')).toEqual([10, 20]);
	});

	it('keeps a malformed JSON array as the raw string', () => {
		expect(deserializeFilterValue('[open,new')).toBe('[open,new');
		expect(deserializeFilterValue('[1,2')).toBe('[1,2');
	});

	it('keeps a JSON object as the raw string — only arrays decode', () => {
		expect(deserializeFilterValue('{"a":1}')).toBe('{"a":1}');
	});
});

describe('parseFilterParams', () => {
	it('parses filters[key] pairs into the filter map', () => {
		const query = new URLSearchParams();
		query.set('filters[category__eq]', 'tools');
		query.set('filters[amount__gte]', '5');
		expect(parseFilterParams(query)).toEqual({
			category__eq: 'tools',
			amount__gte: '5'
		});
	});

	it('ignores keys outside the filters lane', () => {
		const query = new URLSearchParams();
		query.set('filters[status__eq]', 'open');
		query.set('view', 'open');
		query.set('deleted', 'true');
		query.set('filters', 'bogus');
		query.set('filters[a__eq][nested]', 'bogus');
		expect(parseFilterParams(query)).toEqual({ status__eq: 'open' });
	});

	it('decodes array values through the JSON lane', () => {
		const query = new URLSearchParams();
		query.set('filters[status__in]', '["open","new"]');
		expect(parseFilterParams(query)).toEqual({ status__in: ['open', 'new'] });
	});

	it('lets the last duplicate key win, like URLSearchParams.get', () => {
		const query = new URLSearchParams();
		query.append('filters[status__eq]', 'open');
		query.append('filters[status__eq]', 'closed');
		expect(parseFilterParams(query)).toEqual({ status__eq: 'closed' });
	});

	it('round-trips the outbound writer encoding', () => {
		const filters: Record<string, unknown> = {
			category__eq: 'tools',
			status__in: ['open', 'new'],
			amount__between: [10, 20]
		};
		const query = new URLSearchParams();
		for (const [key, value] of Object.entries(filters)) {
			query.set(`filters[${key}]`, serializeFilterValue(value));
		}
		expect(parseFilterParams(query)).toEqual(filters);
	});

	it('returns an empty map when no filters lane exists', () => {
		const query = new URLSearchParams('page=2&view=open');
		expect(parseFilterParams(query)).toEqual({});
	});
});
