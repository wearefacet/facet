// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { DocumentDataSource } from '$lib/datasource/DocumentDataSource.js';
import { DataSourceError } from '$lib/datasource/types.js';
import {
	parseStoredPositions,
	type SchematicLayoutContent,
	type SchematicLayoutSource,
	type SchematicPositions
} from './layout.js';

/**
 * HTTP-backed layout source against `core.SchematicLayout`.
 *
 * The layout document for a domain is found by its `domain` field (an
 * equality-filtered list), not by its row id: the row is created lazily
 * on the first save, so the id is a server-assigned ULID the client
 * cannot predict. The Lua create hook guarantees one row per domain, so
 * the filtered list resolves at most one document.
 *
 * - `load` returns null when the list is empty — no layout yet, the
 *   schematic falls back to the computed layout.
 * - `save` re-reads the row (a concurrent arranger may have created it),
 *   PATCHes the full positions map when it exists, and creates the
 *   document otherwise. Two simultaneous first-saves race at the backend:
 *   the create hook refuses the second row (422), the loser converges on
 *   its next save. Last write wins.
 */
export function createHttpSchematicLayoutSource(): SchematicLayoutSource {
	const ds = new DocumentDataSource<SchematicLayoutContent>('core', 'SchematicLayout');

	async function findDoc(domain: string) {
		const res = await ds.list({ filters: { domain }, items: 1 });
		return res.data[0] ?? null;
	}

	return {
		async load(domain: string): Promise<SchematicPositions | null> {
			const item = await findDoc(domain);
			return item ? parseStoredPositions(item.data) : null;
		},

		async save(domain: string, positions: SchematicPositions): Promise<void> {
			const existing = await findDoc(domain);
			if (existing) {
				try {
					await ds.doc(existing.meta.id).update({ positions });
					return;
				} catch (e) {
					// The row vanished mid-session (deleted by another arranger):
					// fall through to create so the next save re-establishes it.
					if (!(e instanceof DataSourceError && e.status === 404)) throw e;
				}
			}
			await ds.create({ domain, positions });
		}
	};
}
