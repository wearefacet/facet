// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { MockDataDriver } from './MockDriver.js';
import { loadFixtures, loadSeeds, applyFixtures } from './fixture-loader.js';
import { shiftMaintenanceTaskDates } from './maintenanceTaskSeed.js';

// ── Seed data loaded from data/fixtures/ and data/seeds/ ─────────────────────
//
// Each fixture directory under data/fixtures/ and data/seeds/ contains:
//   - definition.yml  — the doctype schema
//   - documents file(s) — optional arrays of { id, content } seed documents.
//     Any *.yml/*.yaml/*.json file that is not `definition.*` or `script.lua`
//     is treated as a documents file; a directory may hold several.
//
// The loader below reads all known fixture and seed directories, registers
// the doctype definitions on the MockDataDriver, and seeds the documents into
// the appropriate domain/doctype DataSource instances.
//
// The data includes edge cases for UI testing: null values, emoji in text,
// long markdown summaries, nested objects, and optional fields.
//
// References use { "$ref": "doc_id" } format — MockDataSource stores them
// as-is in content. Consumers can resolve them by looking up the referenced
// doctype via the same driver.
//
// Note: documents from fixtures use the { id, content } seed format (same
// format as data/seeds/), not the { data, meta } API response shape.
// The loader transforms them for MockDataSource internally.

// ── Public API ───────────────────────────────────────────────────────────────

/**
 * Create a `MockDataDriver` pre-populated with all fixture and seed data
 * for use in Storybook stories and component tests.
 *
 * The returned driver has:
 * - All doctype definitions from `data/seeds/` and `data/fixtures/` registered
 * - All seed/fixture documents populated
 *
 * @example
 * ```ts
 * import { createMockDriver } from '$lib/datasource/mock-seed.js';
 *
 * const driver = createMockDriver();
 * const candidates = driver.domain('hr').doctype('Candidate');
 * const list = await candidates.list();
 * ```
 */
export function createMockDriver(): MockDataDriver {
	const driver = new MockDataDriver();
	seedMockData(driver);
	return driver;
}

/**
 * Seed an existing `MockDataDriver` with all fixture and seed data.
 *
 * This registers doctype definitions AND seeds documents.
 */
export function seedMockData(driver: MockDataDriver): void {
	// Merge seeds and fixtures into one entity list before applying.
	// `MockDomain.doctype()` caches on the first call and ignores seed data
	// passed later, so applying the two lists separately loses documents
	// whenever both define the same entity — e.g. seeds carry
	// `core.DocumentView` rows (per-doctype view templates) while bundles
	// carry the rest.
	const fixtures = loadFixtures();
	const shifted = fixtures.map((f) =>
		f.domain === 'ops' && f.doctype === 'MaintenanceTask'
			? { ...f, documents: shiftMaintenanceTaskDates(f.documents) }
			: f
	);
	const merged = mergeEntities(loadSeeds(), shifted);
	applyFixtures(driver, merged);

	// Auto-seed core.DocType documents from the registered definitions
	// so `driver.domain('core').doctype('DocType').list()` returns all known doctypes.
	// The `display_name`/`search` templates ride along so the ReferencePicker
	// can tell a template-less target from a labelled one (B-296).
	const docTypes = [...driver.doctypeDefinitions.entries()].map(([qualified, def]) => ({
		id: qualified,
		doctype: def.doctype as string,
		domain: def.domain as string,
		color: def.color as string,
		icon: def.icon as string | undefined,
		display_name: def.display_name as string | undefined,
		search: def.search as string | undefined
	}));
	if (docTypes.length > 0) {
		driver.domain('core').doctype('DocType', docTypes);
	}
}

/**
 * Combines the seed entities and the fixture-bundle entities by
 * `{domain}.{doctype}`. Documents concatenate (seeds first, bundles
 * second); definitions carry through from whichever side declares one
 * (seeds declare the core doctypes, bundles the fixture doctypes — the
 * sources never overlap today, and the first non-undefined wins).
 */
function mergeEntities(
	seeds: ReturnType<typeof loadSeeds>,
	fixtures: ReturnType<typeof loadFixtures>
): ReturnType<typeof loadSeeds> {
	const byKey = new Map<string, ReturnType<typeof loadSeeds>[number]>();
	const out: ReturnType<typeof loadSeeds> = [];
	for (const entity of [...seeds, ...fixtures]) {
		const key = `${entity.domain}.${entity.doctype}`;
		const existing = byKey.get(key);
		if (!existing) {
			const copy = { ...entity, documents: [...entity.documents] };
			byKey.set(key, copy);
			out.push(copy);
		} else {
			existing.documents.push(...entity.documents);
			existing.definition ??= entity.definition;
		}
	}
	return out;
}
