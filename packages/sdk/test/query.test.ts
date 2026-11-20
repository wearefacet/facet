// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it } from 'vitest';
import { ApiError, UsageError } from '../src/errors.js';
import { serializeListParams } from '../src/query.js';

// The suffix set from `doc/backend/http-layer.md` (ListRequest). Every
// documented operator must ride the wire under its exact key.
const OPERATORS = [
	'eq',
	'ne',
	'gt',
	'gte',
	'lt',
	'lte',
	'match',
	'starts_with',
	'between',
	'in',
	'currency',
	'contains',
	'overlaps',
	'within'
] as const;

describe('serializeListParams — filters', () => {
	it.each(OPERATORS)('serializes __%s to the exact key the backend parses', (op) => {
		const query = serializeListParams({ filters: { [`status__${op}`]: 'x' } });
		expect(query.get(`filters[status__${op}]`)).toBe('x');
	});

	it('keeps scalar values in their string form', () => {
		const query = serializeListParams({ filters: { age__gt: 18, active__eq: true } });
		expect(query.get('filters[age__gt]')).toBe('18');
		expect(query.get('filters[active__eq]')).toBe('true');
	});

	it('JSON-encodes array values', () => {
		const query = serializeListParams({
			filters: { value__between: ['USD 25000', 'USD 100000'] }
		});
		expect(query.get('filters[value__between]')).toBe('["USD 25000","USD 100000"]');
	});

	it('JSON-encodes an id list for __in', () => {
		const query = serializeListParams({ filters: { id__in: ['01J', '02K'] } });
		expect(query.get('filters[id__in]')).toBe('["01J","02K"]');
	});

	it('passes system-column filters through', () => {
		const query = serializeListParams({
			filters: {
				created_at__gte: '2026-01-01',
				updated_at__lt: '2026-02-01',
				deleted_at__between: ['2026-01-01', '2026-02-01']
			}
		});
		expect(query.get('filters[created_at__gte]')).toBe('2026-01-01');
		expect(query.get('filters[updated_at__lt]')).toBe('2026-02-01');
		expect(query.get('filters[deleted_at__between]')).toBe('["2026-01-01","2026-02-01"]');
	});

	it('passes the bare search key and id filters through', () => {
		const query = serializeListParams({
			filters: { search: 'acme', id__eq: '01J', id__gte: '01J' }
		});
		expect(query.get('filters[search]')).toBe('acme');
		expect(query.get('filters[id__eq]')).toBe('01J');
		expect(query.get('filters[id__gte]')).toBe('01J');
	});

	it('serializes several filter keys side by side', () => {
		const query = serializeListParams({
			filters: { status__eq: 'active', created_at__gte: '2026-01-01' }
		});
		expect(query.get('filters[status__eq]')).toBe('active');
		expect(query.get('filters[created_at__gte]')).toBe('2026-01-01');
	});
});

describe('serializeListParams — sort, paging, flags', () => {
	it('joins the sort array with commas and keeps the `-` prefix', () => {
		const query = serializeListParams({ sort: ['-updated_at', 'id'] });
		expect(query.get('sort')).toBe('-updated_at,id');
	});

	it('omits an empty sort array', () => {
		expect(serializeListParams({ sort: [] }).has('sort')).toBe(false);
	});

	it('serializes page and items', () => {
		const query = serializeListParams({ page: 3, items: 50 });
		expect(query.get('page')).toBe('3');
		expect(query.get('items')).toBe('50');
	});

	it('clamps page 0 to 1', () => {
		const query = serializeListParams({ page: 0 });
		expect(query.get('page')).toBe('1');
	});

	it('clamps items 0 to 1', () => {
		const query = serializeListParams({ items: 0 });
		expect(query.get('items')).toBe('1');
	});

	it('clamps items 1001 to 1000', () => {
		const query = serializeListParams({ items: 1001 });
		expect(query.get('items')).toBe('1000');
	});

	it('serializes aggregate with its field', () => {
		const query = serializeListParams({ aggregate: 'sum', field: 'amount' });
		expect(query.get('aggregate')).toBe('sum');
		expect(query.get('field')).toBe('amount');
	});

	it('passes scope and select through', () => {
		const query = serializeListParams({ scope: 'mine', select: ['id', 'name'] });
		expect(query.get('scope')).toBe('mine');
		expect(query.get('select')).toBe('id,name');
	});

	it('omits an empty select array', () => {
		expect(serializeListParams({ select: [] }).has('select')).toBe(false);
	});

	it('serializes includeDeleted as deleted=true', () => {
		const query = serializeListParams({ includeDeleted: true });
		expect(query.get('deleted')).toBe('true');
	});

	it('omits deleted when includeDeleted is false or absent', () => {
		expect(serializeListParams({}).has('deleted')).toBe(false);
		expect(serializeListParams({ includeDeleted: false }).has('deleted')).toBe(false);
	});

	it('returns an empty query for empty params', () => {
		expect(serializeListParams({}).toString()).toBe('');
	});
});

describe('serializeListParams — local refusals', () => {
	it('raises UsageError for an unknown operator suffix', () => {
		expect(() => serializeListParams({ filters: { status__regex: '^A' } })).toThrow(UsageError);
	});

	it('names the offending key in the message', () => {
		const error = catchUsage(() => serializeListParams({ filters: { status__regex: '^A' } }));
		expect(error?.message).toContain('status__regex');
	});

	it('raises UsageError when count meets page', () => {
		expect(() => serializeListParams({ aggregate: 'count', page: 1 })).toThrow(UsageError);
	});

	it('raises UsageError when count meets items', () => {
		expect(() => serializeListParams({ aggregate: 'count', items: 100 })).toThrow(UsageError);
	});

	it('allows count without page and items', () => {
		const query = serializeListParams({
			aggregate: 'count',
			filters: { status__eq: 'active' },
			sort: ['id']
		});
		expect(query.get('aggregate')).toBe('count');
		expect(query.has('page')).toBe(false);
		expect(query.has('items')).toBe(false);
	});

	it('raises UsageError before any network call', () => {
		// serializeListParams is pure: it touches no socket. The refusal is
		// local by construction.
		expect(() => serializeListParams({ aggregate: 'count', page: 2 })).toThrow(UsageError);
	});

	it('is not an ApiError and carries no status', () => {
		const error = catchUsage(() => serializeListParams({ aggregate: 'count', page: 1 }));
		expect(error).toBeInstanceOf(UsageError);
		expect(error).not.toBeInstanceOf(ApiError);
		expect(error instanceof Error).toBe(true);
		expect('status' in (error as object)).toBe(false);
	});
});

function catchUsage(call: () => unknown): UsageError | null {
	try {
		call();
		return null;
	} catch (caught: unknown) {
		return caught instanceof UsageError ? caught : null;
	}
}
