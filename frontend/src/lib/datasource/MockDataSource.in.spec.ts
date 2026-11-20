// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { MockDataSource } from './MockDataSource.js';

interface DealRow {
	id: string;
	title: string;
	status: string;
	[key: string]: unknown;
}

/**
 * The mock's `__in` filter path: array membership against the stored
 * scalar, mirroring `Util::FilterSet#build_in_clause` — a non-array or
 * empty array degrades to an always-false clause, never to "no filter".
 */
function makeDeals(): MockDataSource<DealRow> {
	const ds = new MockDataSource<DealRow>('crm', 'Deal', []);
	const seed = (id: string, title: string, status: string): void => {
		ds.docs.set(id, {
			id,
			domain: 'crm',
			doc_type: 'Deal',
			content: { id: undefined, title, status } as unknown as DealRow,
			version: 1,
			schema_version: 1,
			created_at: new Date().toISOString(),
			updated_at: new Date().toISOString(),
			mutations: [],
			deleted_at: null
		});
	};
	seed('d1', 'Alpha', 'open');
	seed('d2', 'Beta', 'won');
	seed('d3', 'Gamma', 'lost');
	return ds;
}

describe('MockDataSource __in filter', () => {
	it('matches rows whose value is in the array', async () => {
		const res = await makeDeals().list({ filters: { status__in: ['open', 'won'] } });
		expect(res.data.map((d) => d.data.title).sort()).toEqual(['Alpha', 'Beta']);
	});

	it('matches nothing on an empty array (backend FALSE policy)', async () => {
		const res = await makeDeals().list({ filters: { status__in: [] } });
		expect(res.data).toHaveLength(0);
	});

	it('matches nothing on a non-array value', async () => {
		const res = await makeDeals().list({
			filters: { status__in: 'open' as unknown as string[] }
		});
		expect(res.data).toHaveLength(0);
	});

	it('combines with other filters conjunctively', async () => {
		const res = await makeDeals().list({
			filters: { status__in: ['open', 'won'], title__match: 'Be' }
		});
		expect(res.data.map((d) => d.data.title)).toEqual(['Beta']);
	});
});
