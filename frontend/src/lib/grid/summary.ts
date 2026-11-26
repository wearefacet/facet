// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { DataSource } from '$lib/datasource/interface.js';
import type { GridColumnSummary } from '$lib/collectionView/types.js';

/**
 * The Σ row's server aggregates.
 *
 * Each column's summary is one `list()` call carrying `aggregate` (+ `field`
 * for the field aggregates) with the grid's current filters — the backend
 * (`List::Aggregate`) runs the statement over the whole filtered set, not
 * just the loaded page. The calls run in parallel and a failed column
 * aggregate leaves its cell empty instead of failing the row fetch.
 *
 * The HTTP body of a field aggregate deviates from the list shape
 * (`{ data: { value }, meta: { count, more: false } }` — see
 * `doc/backend/collection-view.md` → Field aggregates): `value` is a JSON
 * number for `integer` / `duration` fields and a `{ ticker => amount }` bag
 * of decimal strings for `money` fields. The single cast below normalizes
 * that shape for the grid.
 */

/** One Σ cell's resolved value. */
export interface FieldSummary {
	/** Number for plain numerics, `{ ticker => amount }` for money, `null`
	 *  for an aggregate over an empty set. */
	value: number | Record<string, string> | null;
	/** Rows that contributed to the value. */
	count: number;
}

export type SummaryKind = Exclude<GridColumnSummary, 'count'>;

/** One column summary fetch. `count` reads the capped filtered total. */
async function fetchOne<T>(
	datasource: DataSource<T>,
	kind: GridColumnSummary,
	field: string | null,
	filters: Record<string, unknown> | undefined
): Promise<FieldSummary> {
	if (kind === 'count') {
		const res = await datasource.list({ aggregate: 'count', filters });
		return { value: res.meta.count, count: res.meta.count };
	}
	const res = (await datasource.list({
		aggregate: kind,
		field: field ?? '',
		filters
	})) as unknown as { data: { value: unknown }; meta: { count: number } };
	return {
		value: (res.data?.value ?? null) as FieldSummary['value'],
		count: res.meta?.count ?? 0
	};
}

/**
 * Fetch every column's summary in parallel. A column whose call rejects
 * (a 422 the gate missed, a dropped request) simply stays out of the map —
 * the Σ cell renders empty. `count` summaries share one call.
 */
export async function fetchSummaries<T>(
	datasource: DataSource<T>,
	columns: ReadonlyArray<{ key: string; summary?: GridColumnSummary }>,
	filters: Record<string, unknown> | undefined
): Promise<Map<string, FieldSummary>> {
	const out = new Map<string, FieldSummary>();
	let sharedCount: Promise<FieldSummary> | null = null;
	await Promise.all(
		columns.map(async (col) => {
			if (!col.summary) return;
			try {
				if (col.summary === 'count') {
					sharedCount ??= fetchOne(datasource, 'count', null, filters);
					out.set(col.key, await sharedCount);
				} else {
					out.set(col.key, await fetchOne(datasource, col.summary, col.key, filters));
				}
			} catch {
				// The cell stays empty — one bad aggregate never blanks the row.
			}
		})
	);
	return out;
}
