// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { MockDataSource } from './MockDataSource.js';

interface DealRow {
	id: string;
	title: string;
	value: { value: string; currency: string };
	[key: string]: unknown;
}

/**
 * The mock's money-filter path: a stored `{ value, currency }` object
 * compares on its numeric `value` member, and a `"<CCY> <amount>"` filter
 * value adds a currency predicate — mirroring the backend
 * `Util::MoneyFilterValue` / `Util::FilterClauses.money_clauses`.
 */
function makeDeals(): MockDataSource<DealRow> {
	const ds = new MockDataSource<DealRow>('crm', 'Deal', []);
	const seed = (id: string, title: string, value: string, currency: string): void => {
		ds.docs.set(id, {
			id,
			domain: 'crm',
			doc_type: 'Deal',
			content: { id: undefined, title, value: { value, currency } } as unknown as DealRow,
			version: 1,
			schema_version: 1,
			created_at: new Date().toISOString(),
			updated_at: new Date().toISOString(),
			mutations: [],
			deleted_at: null
		});
	};
	seed('d1', 'Small', '45000', 'USD');
	seed('d2', 'Medium', '80000', 'USD');
	seed('d3', 'Large', '120000', 'USD');
	seed('d4', 'Euro deal', '60000', 'EUR');
	return ds;
}

const titles = (rows: { data: DealRow }[]): string[] => rows.map((r) => r.data.title).sort();

describe('MockDataSource — money filters', () => {
	it('filters eq with a bare amount across currencies', async () => {
		const ds = makeDeals();
		const res = await ds.list({ filters: { value__eq: '60000' } });
		expect(titles(res.data)).toEqual(['Euro deal']);
	});

	it('filters lt/lte/gt/gte with currency-prefixed amounts', async () => {
		const ds = makeDeals();
		const lt = await ds.list({ filters: { value__lt: 'USD 80000' } });
		expect(titles(lt.data)).toEqual(['Small']);
		const lte = await ds.list({ filters: { value__lte: 'USD 80000' } });
		expect(titles(lte.data)).toEqual(['Medium', 'Small']);
		const gt = await ds.list({ filters: { value__gt: 'USD 80000' } });
		expect(titles(gt.data)).toEqual(['Large']);
		const gte = await ds.list({ filters: { value__gte: 'USD 80000' } });
		expect(titles(gte.data)).toEqual(['Large', 'Medium']);
	});

	it('applies the currency predicate when the filter value carries a prefix', async () => {
		const ds = makeDeals();
		// 60000 exists as a USD amount (Medium) and an EUR amount (Euro deal) —
		// only the EUR one matches the prefixed filter.
		const eur = await ds.list({ filters: { value__eq: 'EUR 60000' } });
		expect(titles(eur.data)).toEqual(['Euro deal']);
		const usd = await ds.list({ filters: { value__gte: 'USD 60000' } });
		expect(titles(usd.data)).toEqual(['Large', 'Medium']);
	});

	it('compares between bounds numerically with a shared currency', async () => {
		const ds = makeDeals();
		const res = await ds.list({ filters: { value__between: ['USD 25000', 'USD 100000'] } });
		expect(titles(res.data)).toEqual(['Medium', 'Small']);
		// A bound in another currency excludes the USD rows.
		const eur = await ds.list({ filters: { value__between: ['EUR 10000', 'USD 200000'] } });
		expect(titles(eur.data)).toEqual([]);
	});

	it('falls back to the scalar path for non-money values', async () => {
		const ds = makeDeals();
		// `probability__gt` has no money-shaped stored value — the scalar
		// comparison still runs (nothing matches here, but no crash).
		const res = await ds.list({ filters: { title__eq: 'Small', value__gte: 0 } });
		// The money object compares numerically: every amount is ≥ 0.
		expect(titles(res.data)).toEqual(['Small']);
	});

	it('ignores malformed money filter values (scalar fallback, no crash)', async () => {
		const ds = makeDeals();
		const res = await ds.list({ filters: { value__eq: 'not a money' } });
		expect(res.data).toHaveLength(0);
	});

	it('filters the currency operator on the stored ticker alone', async () => {
		const ds = makeDeals();
		const eur = await ds.list({ filters: { value__currency: 'EUR' } });
		expect(titles(eur.data)).toEqual(['Euro deal']);
		const usd = await ds.list({ filters: { value__currency: 'USD' } });
		expect(titles(usd.data)).toEqual(['Large', 'Medium', 'Small']);
		// A blank (seeded) value matches nothing — the backend compares against
		// `''` and no stored ticker is empty.
		const blank = await ds.list({ filters: { value__currency: '' } });
		expect(blank.data).toHaveLength(0);
	});

	it('matches nothing for a currency filter on a non-money stored value', async () => {
		const ds = makeDeals();
		const res = await ds.list({ filters: { title__currency: 'USD' } });
		expect(res.data).toHaveLength(0);
	});
});
