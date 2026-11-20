// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { UsageError } from './errors.js';

/** Aggregate modes the backend serves on a collection list. */
export type AggregateMode = 'count' | 'sum' | 'avg' | 'min' | 'max';

/** Parameters one collection list call accepts. */
export interface ListParams {
	/** 1-based page number. Clamped to 1 or more. */
	page?: number;
	/** Page size. Clamped to the range 1..1000. */
	items?: number;
	/** Filters in the `field__op` wire form, e.g. `status__eq`. A bare key such as `search` rides as-is. */
	filters?: Record<string, unknown>;
	/** Sort fields. A `-` prefix means descending. */
	sort?: string[];
	/**
	 * Aggregate mode. `count` needs no `field`; `sum`, `avg`, `min`, and `max`
	 * need one. The backend ignores `page` and `items` under `count`, so the
	 * builder refuses that mix before any network call.
	 */
	aggregate?: AggregateMode;
	/** Target field of `sum`, `avg`, `min`, or `max`. */
	field?: string;
	/** Name of one named scope declared on the doctype. */
	scope?: string;
	/** Field projection. Only these fields ride the response. */
	select?: string[];
	/** Set the `deleted` flag. The list then returns tombstones — the trash listing. */
	includeDeleted?: boolean;
}

/**
 * Operator suffixes the backend filter grammar serves. The list mirrors
 * `doc/backend/http-layer.md` (ListRequest). The backend stays the validator
 * of record for which operator serves which field family; this set only
 * catches a typo before any network call.
 */
const OPERATORS: ReadonlySet<string> = new Set([
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
]);

const MIN_PAGE = 1;
const MIN_ITEMS = 1;
const MAX_ITEMS = 1000;

/**
 * Serializes list parameters into the query-string form the backend parses:
 * `page`, `items`, `filters[field__op]=value`, `sort=-field,field`,
 * `aggregate`, `field`, `scope`, `select`, and `deleted=true`.
 *
 * Array filter values ride JSON-encoded; the backend decodes a `filters[...]`
 * value that parses as a JSON array back into a real array. Scalar values
 * keep their string form, so numeric-string comparisons behave as the backend
 * expects.
 *
 * Raises `UsageError`, before any network call, when a filter key carries an
 * unknown operator suffix, or when `aggregate: 'count'` meets `page` or
 * `items` — the backend would silently ignore that mix.
 */
export function serializeListParams(params: ListParams): URLSearchParams {
	if (params.aggregate === 'count' && (params.page !== undefined || params.items !== undefined)) {
		throw new UsageError(
			"aggregate: 'count' ignores page and items. Drop them, so the call does not ask for a page the server will not serve."
		);
	}
	if (params.filters !== undefined) {
		assertKnownOperators(params.filters);
	}

	const query = new URLSearchParams();
	if (params.page !== undefined) {
		query.set('page', String(clampPage(params.page)));
	}
	if (params.items !== undefined) {
		query.set('items', String(clampItems(params.items)));
	}
	if (params.filters !== undefined) {
		for (const [key, value] of Object.entries(params.filters)) {
			query.set(`filters[${key}]`, serializeFilterValue(value));
		}
	}
	if (params.sort !== undefined && params.sort.length > 0) {
		query.set('sort', params.sort.join(','));
	}
	if (params.aggregate !== undefined) {
		query.set('aggregate', params.aggregate);
	}
	if (params.field !== undefined) {
		query.set('field', params.field);
	}
	if (params.scope !== undefined) {
		query.set('scope', params.scope);
	}
	if (params.select !== undefined && params.select.length > 0) {
		query.set('select', params.select.join(','));
	}
	if (params.includeDeleted) {
		query.set('deleted', 'true');
	}
	return query;
}

/**
 * Checks every filter key against the operator set. The backend splits a key
 * on the first `__` and treats the rest as the operator, so this check uses
 * the same split. A bare key (no `__`) rides as-is; the backend validates the
 * field name and treats it as `__eq`.
 */
function assertKnownOperators(filters: Record<string, unknown>): void {
	for (const key of Object.keys(filters)) {
		const splitAt = key.indexOf('__');
		if (splitAt === -1) {
			continue;
		}
		const operator = key.slice(splitAt + 2);
		if (!OPERATORS.has(operator)) {
			throw new UsageError(
				`Unknown filter operator '${operator}' in '${key}'. Use one of: ${[...OPERATORS].join(', ')}.`
			);
		}
	}
}

function clampPage(page: number): number {
	return Math.max(MIN_PAGE, Math.trunc(page));
}

function clampItems(items: number): number {
	return Math.min(MAX_ITEMS, Math.max(MIN_ITEMS, Math.trunc(items)));
}

/**
 * Serializes one filter value. Scalars keep their string form. Arrays cannot
 * cross a query string as scalars, so they go out JSON-encoded.
 */
function serializeFilterValue(value: unknown): string {
	return Array.isArray(value) ? JSON.stringify(value) : String(value);
}
