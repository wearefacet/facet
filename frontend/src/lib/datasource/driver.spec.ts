// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { DocumentDataDriver } from './DocumentDriver.js';
import { MockDataDriver } from './MockDriver.js';
import type { DataSource } from './interface.js';

// ── DocumentDataDriver (real) ──────────────────────────────────────────────

describe('DocumentDataDriver', () => {
	it('returns a Domain that produces DataSource instances', () => {
		const driver = new DocumentDataDriver('http://localhost:3000');
		const hr = driver.domain('hr');
		const employees = hr.doctype('Employee');

		expect(employees).toBeDefined();
		expect(typeof employees.list).toBe('function');
		expect(typeof employees.create).toBe('function');
	});

	it('caches Domain instances', () => {
		const driver = new DocumentDataDriver('http://localhost:3000');
		expect(driver.domain('hr')).toBe(driver.domain('hr'));
	});

	it('produces a DataSource that includes the base URL in the path', async () => {
		const driver = new DocumentDataDriver('http://test.local');
		const ds: DataSource = driver.domain('crm').doctype('Contact');
		expect((ds as unknown as { basePath: string }).basePath).toBe(
			'http://test.local/Api/crm/Contact'
		);
	});

	it('supports chained driver.domain().doctype()', () => {
		const driver = new DocumentDataDriver('http://localhost:3000');
		const ds1 = driver.domain('hr').doctype('Employee');
		const ds2 = driver.domain('hr').doctype('Department');
		const ds3 = driver.domain('org').doctype('Org');

		expect(ds1).not.toBe(ds2);
		expect(ds3).not.toBe(ds1);
	});
});

// ── MockDataDriver ─────────────────────────────────────────────────────────

describe('MockDataDriver', () => {
	it('returns a Domain that produces DataSource instances', () => {
		const driver = new MockDataDriver();
		const hr = driver.domain('hr');
		const employees = hr.doctype('Employee');

		expect(employees).toBeDefined();
		expect(typeof employees.list).toBe('function');
		expect(typeof employees.create).toBe('function');
	});

	it('caches Domain instances', () => {
		const driver = new MockDataDriver();
		expect(driver.domain('hr')).toBe(driver.domain('hr'));
	});

	it('caches doctype DataSources within a domain', () => {
		const driver = new MockDataDriver();
		const hr = driver.domain('hr');
		expect(hr.doctype('Employee')).toBe(hr.doctype('Employee'));
	});

	it('list returns empty for a fresh doctype', async () => {
		const driver = new MockDataDriver();
		const list = await driver.domain('hr').doctype('Employee').list();
		expect(list.data).toEqual([]);
		expect(list.meta.count).toBe(0);
		expect(list.meta.more).toBe(false);
	});

	it('create and list round-trips', async () => {
		const driver = new MockDataDriver();
		const ds = driver.domain('hr').doctype('Employee') as DataSource<{ name: string }>;

		await ds.create({ name: 'Alice' });
		await ds.create({ name: 'Bob' });

		const list = await ds.list();
		expect(list.data.length).toBe(2);
		expect(list.meta.count).toBe(2);
	});

	it('shares storage across different domains and doctypes', async () => {
		const driver = new MockDataDriver();

		// Seed via one path
		const hrEmployees = driver.domain('hr').doctype('Employee');
		await hrEmployees.create({ name: 'Alice', department_id: 'd1' });

		// Read via another path to the same domain/doctype
		const sameDs = driver.domain('hr').doctype('Employee');
		const list = await sameDs.list();
		expect(list.data).toHaveLength(1);
		expect(list.data[0].data.name).toBe('Alice');
	});

	it('separates data across domains through the same shared store', async () => {
		const driver = new MockDataDriver();

		const hrEmployees = driver.domain('hr').doctype('Employee');
		const orgDepts = driver.domain('org').doctype('Department');

		await hrEmployees.create({ name: 'Alice' });
		await orgDepts.create({ name: 'Engineering' });

		// Each doctype sees only its own docs
		const hrList = await hrEmployees.list();
		expect(hrList.data).toHaveLength(1);
		expect(hrList.data[0].data.name).toBe('Alice');

		const orgList = await orgDepts.list();
		expect(orgList.data).toHaveLength(1);
		expect(orgList.data[0].data.name).toBe('Engineering');
	});

	it('supports seed data via doctype()', async () => {
		const driver = new MockDataDriver();

		const ds = driver.domain('hr').doctype('Employee', [
			{ id: 'e1', name: 'Alice' },
			{ id: 'e2', name: 'Bob' }
		]);

		const list = await ds.list();
		expect(list.data).toHaveLength(2);
	});

	it('seed data is only applied on first doctype() call', async () => {
		const driver = new MockDataDriver();

		// First call seeds
		driver.domain('hr').doctype('Employee', [{ id: 'e1', name: 'Alice' }]);
		// Second call with different seed — ignored because cached
		const ds = driver.domain('hr').doctype('Employee', [{ id: 'e2', name: 'Bob' }]);

		const list = await ds.list();
		expect(list.data).toHaveLength(1);
		expect(list.data[0].data.name).toBe('Alice');
	});

	it('supports full CRUD through the driver', async () => {
		const driver = new MockDataDriver();
		const ds = driver.domain('crm').doctype('Contact');

		const created = await ds.create({ name: 'Alice', email: 'alice@test.com' });
		expect(created.data.name).toBe('Alice');

		const doc = await ds.doc(created.meta.id).show();
		expect(doc.data.email).toBe('alice@test.com');

		const updated = await ds.doc(created.meta.id).update({ name: 'Alice Smith' });
		expect(updated.data.name).toBe('Alice Smith');

		const listBefore = await ds.list();
		expect(listBefore.data).toHaveLength(1);

		await ds.doc(created.meta.id).delete();

		const listAfter = await ds.list();
		expect(listAfter.data).toHaveLength(0);
	});

	it('supports custom actions', async () => {
		const driver = new MockDataDriver();
		const ds = driver.domain('hr').doctype('Employee');

		// Need to access the MockDataSource directly to register action handlers
		// Since the driver returns DataSource interface, we cast
		const mockDs = ds as import('./MockDataSource.js').MockDataSource;
		mockDs.onAction('promote', (_doc, args) => ({
			name: _doc.content.name,
			level: args.level as number
		}));

		const created = await ds.create({ name: 'Alice' });
		const result = await ds.doc(created.meta.id).action('promote', { level: 4 });
		expect(result.data.level).toBe(4);
	});

	it('exposes docs map on the driver', () => {
		const driver = new MockDataDriver();
		expect(driver.docs).toBeInstanceOf(Map);
	});

	// ── Capped count / `more` contract ───────────────────────────────────
	// Mirrors the backend `Helpers.capped_count`: the count is bounded to the
	// CAP (1000) rows starting from the request's offset. `count` is the
	// inclusive upper bound of what's known to exist beyond that offset
	// (`offset + min(rawCount, CAP)`), and `more` is true only when the cap
	// was hit — signaling "at least this many, possibly more", NEVER "there
	// is a next page". Next-page presence is derived from
	// `data.length === itemsPerPage`.
	describe('capped count / more flag (matches backend Helpers.capped_count)', () => {
		it('under the cap: count is exact, more is false (page 1)', async () => {
			const driver = new MockDataDriver();
			const ds = driver.domain('hr').doctype('Employee');
			for (let i = 0; i < 5; i++) await ds.create({ name: `E${i}` });

			const list = await ds.list({ items: 10 });
			expect(list.data).toHaveLength(5);
			expect(list.meta.count).toBe(5); // offset 0 + min(5, 1000)
			expect(list.meta.more).toBe(false);
		});

		it('under the cap on a later page: count carries the offset', async () => {
			const driver = new MockDataDriver();
			const ds = driver.domain('hr').doctype('Employee');
			for (let i = 0; i < 8; i++) await ds.create({ name: `E${i}` });

			// Page 2 of 5 items → offset 5, 3 rows remain (≤ CAP).
			const list = await ds.list({ page: 2, items: 5 });
			expect(list.data).toHaveLength(3);
			expect(list.meta.count).toBe(8); // offset 5 + min(3, 1000)
			expect(list.meta.more).toBe(false);
		});

		it('over the cap: count is clamped to offset + CAP, more is true', async () => {
			const driver = new MockDataDriver();
			const ds = driver.domain('hr').doctype('Employee');
			for (let i = 0; i < 1500; i++) await ds.create({ name: `E${i}` });

			// Page 5 of 10 → offset 40, ≥1000 rows remain → cap hit.
			const list = await ds.list({ page: 5, items: 10 });
			expect(list.data).toHaveLength(10); // page slice still returned
			expect(list.meta.count).toBe(1040); // offset 40 + 1000
			expect(list.meta.more).toBe(true);
		});

		it('history() honors the same cap contract', async () => {
			const driver = new MockDataDriver();
			const ds = driver.domain('hr').doctype('Employee');
			const created = await ds.create({ name: 'Alice' });
			const ref = ds.doc(created.meta.id);
			// Each update produces one mutation; create already produced one.
			for (let i = 0; i < 3; i++) {
				await ref.update({ name: `Alice${i}` });
			}

			const history = await ref.history({ items: 2 });
			expect(history.data).toHaveLength(2); // newest-first page slice
			expect(history.meta.count).toBe(4); // offset 0 + min(4, 1000)
			expect(history.meta.more).toBe(false);
		});
	});

	// ── aggregate=count ───────────────────────────────────────────────────
	// Count mode mirrors the backend's `?aggregate=count` route (see
	// src/document/list.cr). It runs no row read; the caller learns the full
	// filtered total capped at 1000 from offset 0 (page/items are ignored).
	describe('aggregate=count (mirrors backend count mode)', () => {
		it('returns an empty data array with the filtered total', async () => {
			const driver = new MockDataDriver();
			const ds = driver.domain('hr').doctype('Employee');
			for (let i = 0; i < 3; i++) await ds.create({ name: `E${i}`, status: 'active' });
			for (let i = 0; i < 2; i++) await ds.create({ name: `I${i}`, status: 'inactive' });

			const result = await ds.list({ aggregate: 'count' });
			expect(result.data).toEqual([]);
			expect(result.meta.count).toBe(5);
			expect(result.meta.more).toBe(false);
		});

		it('applies filters the same as a normal list', async () => {
			const driver = new MockDataDriver();
			const ds = driver.domain('hr').doctype('Employee');
			for (let i = 0; i < 3; i++) await ds.create({ name: `E${i}`, status: 'active' });
			for (let i = 0; i < 2; i++) await ds.create({ name: `I${i}`, status: 'inactive' });

			const result = await ds.list({
				aggregate: 'count',
				filters: { status__eq: 'active' }
			});
			expect(result.data).toEqual([]);
			expect(result.meta.count).toBe(3);
		});

		it('ignores page and items — reports the full total from offset 0', async () => {
			const driver = new MockDataDriver();
			const ds = driver.domain('hr').doctype('Employee');
			for (let i = 0; i < 7; i++) await ds.create({ name: `E${i}` });

			// page=2, items=2 would yield count=4 in normal mode because of the
			// offset — count mode ignores pagination entirely.
			const result = await ds.list({ aggregate: 'count', page: 2, items: 2 });
			expect(result.meta.count).toBe(7);
			expect(result.meta.more).toBe(false);
		});

		it('capped count hits the 1000 cap and reports more=true', async () => {
			const driver = new MockDataDriver();
			const ds = driver.domain('hr').doctype('Employee');
			for (let i = 0; i < 1500; i++) await ds.create({ name: `E${i}` });

			const result = await ds.list({ aggregate: 'count' });
			expect(result.data).toEqual([]);
			expect(result.meta.count).toBe(1000); // 0 + min(1500, 1000)
			expect(result.meta.more).toBe(true);
		});
	});
});
