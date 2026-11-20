// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { buildNavModel, domainProjectionToNavDomain, navDoctypesForDomain } from './navModel';
import { MockDataDriver } from './datasource/MockDriver';
import type { ListParams } from './datasource/types';
import { setPreviewSession, clearPreviewSession } from './previewSession.svelte';

function makeDriver(): MockDataDriver {
	const driver = new MockDataDriver();

	// core.Domain documents — seed data passed as { id, ...content }
	driver.domain('core').doctype('Domain', [
		{ id: 'hr', color: '#FF0000' },
		{ id: 'crm', color: '#00FF00' }
	]);

	// Doctype definitions (registered on the driver's registry)
	driver.registerDoctype('hr', 'Employee', {
		domain: 'hr',
		doctype: 'Employee',
		color: '#AAA',
		aggregate_root: true
	});
	driver.registerDoctype('crm', 'Company', {
		domain: 'crm',
		doctype: 'Company',
		color: '#BBB',
		aggregate_root: true
	});
	driver.registerDoctype('crm', 'Contact', {
		domain: 'crm',
		doctype: 'Contact',
		color: '#CCC',
		aggregate_root: true
	});

	return driver;
}

function registerChild(
	driver: MockDataDriver,
	qualified: { domain: string; doctype: string; member_of: string; nav_visible?: boolean }
) {
	driver.registerDoctype(qualified.domain, qualified.doctype, {
		domain: qualified.domain,
		doctype: qualified.doctype,
		member_of: qualified.member_of,
		nav_visible: qualified.nav_visible
	});
}

describe('buildNavModel', () => {
	it('builds all domains and doctypes when no permissions filter is provided', async () => {
		const driver = makeDriver();
		const model = await buildNavModel(driver);

		const domains = model.map((d) => d.id).sort();
		expect(domains).toEqual(['crm', 'hr']);

		const hr = model.find((d) => d.id === 'hr')!;
		expect(hr.doctypes.map((d) => d.qualified)).toEqual(['hr.Employee']);
		// Counts are no longer resolved by buildNavModel — they stay undefined
		// until the sidebar's lazy count load runs for the active domain.
		expect(hr.doctypes[0].count).toBeUndefined();

		const crm = model.find((d) => d.id === 'crm')!;
		expect(crm.doctypes.map((d) => d.qualified).sort()).toEqual(['crm.Company', 'crm.Contact']);
	});

	it('prefers the definition label for the nav label, falling back to the doctype name', async () => {
		const driver = makeDriver();
		driver.registerDoctype('crm', 'CompanyMembership', {
			domain: 'crm',
			doctype: 'CompanyMembership',
			label: 'Membership',
			color: '#DDD',
			aggregate_root: true
		});

		const model = await buildNavModel(driver);
		const crm = model.find((d) => d.id === 'crm')!;

		const membership = crm.doctypes.find((d) => d.qualified === 'crm.CompanyMembership');
		expect(membership?.label).toBe('Membership');
		// No label set — the bare doctype name stays the label.
		const company = crm.doctypes.find((d) => d.qualified === 'crm.Company');
		expect(company?.label).toBe('Company');
		// An empty label falls back too.
		driver.registerDoctype('hr', 'Employee', {
			domain: 'hr',
			doctype: 'Employee',
			label: '  ',
			color: '#AAA',
			aggregate_root: true
		});
		const model2 = await buildNavModel(driver);
		const hr = model2.find((d) => d.id === 'hr')!;
		expect(hr.doctypes[0].label).toBe('Employee');
	});

	it('shows all doctypes when the admin wildcard permission is present', async () => {
		const driver = makeDriver();
		const model = await buildNavModel(driver, { '*.*': ['*'] });
		expect(model.map((d) => d.id).sort()).toEqual(['crm', 'hr']);
	});

	it('filters out doctypes without read permission', async () => {
		const driver = makeDriver();
		const model = await buildNavModel(driver, {
			'crm.Company': ['read'],
			'crm.Contact': ['create']
		});

		// hr is not in permissions at all → hidden
		expect(model.map((d) => d.id)).toEqual(['crm']);

		const crm = model.find((d) => d.id === 'crm')!;
		// Company has read → visible; Contact only has create → hidden
		expect(crm.doctypes.map((d) => d.qualified)).toEqual(['crm.Company']);
	});

	it('shows a doctype when the wildcard action is granted', async () => {
		const driver = makeDriver();
		const model = await buildNavModel(driver, {
			'hr.Employee': ['*']
		});

		expect(model.map((d) => d.id)).toEqual(['hr']);
		expect(model[0].doctypes.map((d) => d.qualified)).toEqual(['hr.Employee']);
	});

	it('returns empty array when no permissions grant read', async () => {
		const driver = makeDriver();
		const model = await buildNavModel(driver, {
			'hr.Employee': ['update'],
			'crm.Company': ['delete']
		});
		// No read permissions → no doctypes visible → no domains visible
		expect(model).toEqual([]);
	});

	it('includes empty domains in draft mode so fresh drafts appear', async () => {
		const driver = new MockDataDriver();
		// core.Domain documents — one live, one empty draft with a name.
		driver.domain('core').doctype('Domain', [
			{ id: 'hr', color: '#FF0000' },
			{ id: '_abc', draft: true, name: 'Logistics' }
		]);
		// A doctype on the live domain so it would show up in live mode too.
		driver.registerDoctype('hr', 'Employee', {
			domain: 'hr',
			doctype: 'Employee',
			color: '#AAA',
			aggregate_root: true
		});

		const model = await buildNavModel(driver, undefined, { drafts: true });

		expect(model.map((d) => d.id)).toEqual(['_abc']);
		expect(model[0].doctypes).toEqual([]);
		// The name field drives the label, suffixed with (draft).
		expect(model[0].label).toBe('Logistics (draft)');
	});

	it('marks doctypes as pinned when listed in the pinned set', async () => {
		const driver = makeDriver();
		const model = await buildNavModel(driver, undefined, {
			pinnedDoctypes: ['crm.Company']
		});

		const crm = model.find((d) => d.id === 'crm')!;
		const company = crm.doctypes.find((d) => d.qualified === 'crm.Company')!;
		const contact = crm.doctypes.find((d) => d.qualified === 'crm.Contact')!;
		expect(company.pinned).toBe(true);
		expect(contact.pinned).toBe(false);
	});

	it('does not mark any doctype pinned when the pinned set is empty', async () => {
		const driver = makeDriver();
		const model = await buildNavModel(driver);

		const crm = model.find((d) => d.id === 'crm')!;
		for (const dt of crm.doctypes) {
			expect(dt.pinned).toBe(false);
		}
	});

	it('leaves every doctype count undefined so the sidebar can fetch them lazily', async () => {
		// Regression guard for the lazy-count refactor: buildNavModel used to
		// issue one `aggregate=count` call per visible doctype. That work now
		// lives in `navCounts.svelte.ts`'s `loadForDomain`, triggered by
		// `NavPanel` when a domain becomes active. buildNavModel must not make
		// any per-doctype list calls — only the `core.Domain` listing and the
		// `DoctypeRegistry` snapshot.
		const driver = makeDriver();
		// Seed documents so a count, if it were being computed, would be
		// non-zero and surface as a numeric value.
		await driver.domain('crm').doctype('Company').create({ name: 'Acme' });
		await driver.domain('crm').doctype('Company').create({ name: 'Globex' });

		const listCalls: ListParams[] = [];
		const companyDs = driver.domain('crm').doctype('Company') as unknown as {
			list(params?: ListParams): Promise<unknown>;
		};
		const origList = companyDs.list.bind(companyDs);
		companyDs.list = (params?: ListParams) => {
			listCalls.push(params ?? {});
			return origList(params);
		};

		const model = await buildNavModel(driver);

		for (const domain of model) {
			for (const dt of domain.doctypes) {
				expect(dt.count).toBeUndefined();
			}
		}

		// No list calls should have been made against any doctype's
		// DataSource — the spy wraps `crm.Company.list`, which buildNavModel
		// must not touch.
		expect(listCalls.length).toBe(0);
	});

	describe('child doctype tree', () => {
		it('nests member_of children under their parent by default', async () => {
			const driver = makeDriver();
			registerChild(driver, { domain: 'crm', doctype: 'CompanyMembership', member_of: 'Company' });

			const model = await buildNavModel(driver);
			const crm = model.find((d) => d.id === 'crm')!;
			// The child no longer needs nav_visible — the tree surfaces it under
			// its parent.
			expect(crm.doctypes.map((d) => d.qualified)).toEqual(['crm.Company', 'crm.Contact']);
			expect(crm.doctypes[0].children?.map((d) => d.qualified)).toEqual(['crm.CompanyMembership']);
			expect(crm.doctypes[1].children).toBeUndefined();
		});

		it('keeps a nav_visible child nested when the parent is visible', async () => {
			// With the tree, the opt-in flag only matters when the parent cannot
			// host the child; a visible parent nests the child regardless.
			const driver = makeDriver();
			registerChild(driver, {
				domain: 'crm',
				doctype: 'CompanyMembership',
				member_of: 'Company',
				nav_visible: true
			});

			const model = await buildNavModel(driver);
			const crm = model.find((d) => d.id === 'crm')!;
			const company = crm.doctypes.find((d) => d.qualified === 'crm.Company')!;
			expect(company.children?.map((d) => d.qualified)).toContain('crm.CompanyMembership');
		});

		it('drops a child from the tree when RBAC does not grant read on it', async () => {
			// Visibility of the child is its own grant decision — nesting never
			// bypasses the permission manifest.
			const driver = makeDriver();
			registerChild(driver, {
				domain: 'crm',
				doctype: 'CompanyMembership',
				member_of: 'Company',
				nav_visible: true
			});

			const model = await buildNavModel(driver, { 'crm.Company': ['read'] });
			const crm = model.find((d) => d.id === 'crm')!;
			expect(crm.doctypes.map((d) => d.qualified)).toEqual(['crm.Company']);
			expect(crm.doctypes[0].children).toBeUndefined();
		});

		it('keeps children-only spellings (no member_of) top-level', async () => {
			// The children-only composition form (parent declares `children:`,
			// child has no `member_of`) is a first-class browsable doctype.
			const driver = makeDriver();
			driver.registerDoctype('crm', 'Note', {
				domain: 'crm',
				doctype: 'Note',
				aggregate_root: false
			});

			const model = await buildNavModel(driver);
			const crm = model.find((d) => d.id === 'crm')!;
			expect(crm.doctypes.map((d) => d.qualified)).toContain('crm.Note');
		});

		it('falls back to a flat row for a nav_visible child whose parent is missing', async () => {
			const driver = makeDriver();
			registerChild(driver, {
				domain: 'crm',
				doctype: 'OrphanMembership',
				member_of: 'Missing',
				nav_visible: true
			});
			registerChild(driver, { domain: 'crm', doctype: 'QuietOrphan', member_of: 'Missing' });

			const model = await buildNavModel(driver);
			const crm = model.find((d) => d.id === 'crm')!;
			// The opted-in orphan shows flat; the unopted-in one stays hidden.
			expect(crm.doctypes.map((d) => d.qualified)).toContain('crm.OrphanMembership');
			expect(crm.doctypes.map((d) => d.qualified)).not.toContain('crm.QuietOrphan');
		});

		it('falls back to a flat row for a nav_visible child whose parent is RBAC-hidden', async () => {
			const driver = makeDriver();
			registerChild(driver, {
				domain: 'crm',
				doctype: 'CompanyMembership',
				member_of: 'Company',
				nav_visible: true
			});

			// The parent's read grant is missing, the child keeps its own.
			const model = await buildNavModel(driver, { 'crm.CompanyMembership': ['read'] });
			const crm = model.find((d) => d.id === 'crm')!;
			expect(crm.doctypes.map((d) => d.qualified)).toEqual(['crm.CompanyMembership']);
		});

		it('hides an unopted-in child whose parent is RBAC-hidden', async () => {
			const driver = makeDriver();
			registerChild(driver, { domain: 'crm', doctype: 'CompanyMembership', member_of: 'Company' });

			const model = await buildNavModel(driver, { 'crm.Company': ['read'] });
			const crm = model.find((d) => d.id === 'crm')!;
			expect(crm.doctypes.map((d) => d.qualified)).toEqual(['crm.Company']);
			expect(crm.doctypes[0].children).toBeUndefined();
		});

		it('nests grandchildren two levels deep', async () => {
			const driver = makeDriver();
			registerChild(driver, { domain: 'crm', doctype: 'Membership', member_of: 'Company' });
			registerChild(driver, { domain: 'crm', doctype: 'MembershipLine', member_of: 'Membership' });

			const model = await buildNavModel(driver);
			const crm = model.find((d) => d.id === 'crm')!;
			const company = crm.doctypes.find((d) => d.qualified === 'crm.Company')!;
			const membership = company.children?.find((d) => d.qualified === 'crm.Membership');
			expect(membership?.children?.map((d) => d.qualified)).toEqual(['crm.MembershipLine']);
		});

		it('never resolves a member_of cycle into the tree', async () => {
			// Malformed definitions loop A → B → A. No node may recurse forever or
			// nest inside the loop; both fall back to the broken-chain rule.
			const driver = makeDriver();
			registerChild(driver, { domain: 'crm', doctype: 'LoopA', member_of: 'LoopB' });
			registerChild(driver, { domain: 'crm', doctype: 'LoopB', member_of: 'LoopA' });

			const model = await buildNavModel(driver);
			const crm = model.find((d) => d.id === 'crm')!;
			expect(crm.doctypes.map((d) => d.qualified).sort()).toEqual(['crm.Company', 'crm.Contact']);
			for (const dt of crm.doctypes) expect(dt.children).toBeUndefined();
		});

		it('does not nest a child across domains', async () => {
			// member_of resolves inside the child's own domain only; a bare name
			// that only exists in another domain is an orphan.
			const driver = makeDriver();
			registerChild(driver, { domain: 'crm', doctype: 'EmployeeLink', member_of: 'Employee' });

			const model = await buildNavModel(driver);
			const crm = model.find((d) => d.id === 'crm')!;
			expect(crm.doctypes.map((d) => d.qualified)).toEqual(['crm.Company', 'crm.Contact']);
		});

		it('marks nested children pinned when listed in the pinned set', async () => {
			const driver = makeDriver();
			registerChild(driver, { domain: 'crm', doctype: 'CompanyMembership', member_of: 'Company' });

			const model = await buildNavModel(driver, undefined, {
				pinnedDoctypes: ['crm.CompanyMembership']
			});
			const crm = model.find((d) => d.id === 'crm')!;
			const company = crm.doctypes.find((d) => d.qualified === 'crm.Company')!;
			const membership = company.children?.find((d) => d.qualified === 'crm.CompanyMembership');
			expect(membership?.pinned).toBe(true);
		});
	});

	describe('wildcard fallback visibility', () => {
		it('shows every doctype when the *.* line carries read', async () => {
			const driver = makeDriver();
			const model = await buildNavModel(driver, { '*.*': ['read'] });
			expect(model.map((d) => d.id).sort()).toEqual(['crm', 'hr']);
		});

		it('hides a doctype carved out by *.*.except.<action> and never renders the reserved key', async () => {
			// The reserved "*.*.except.<action>" keys answer per doctype through
			// the visibility predicate — they can never surface as a doctype or
			// a domain, and the carve-out's prefix grammar hides the subtree.
			const driver = makeDriver();
			const model = await buildNavModel(driver, {
				'*.*': ['read'],
				'*.*.except.read': ['crm.Company']
			});
			expect(model.map((d) => d.id).sort()).toEqual(['crm', 'hr']);
			const crm = model.find((d) => d.id === 'crm')!;
			expect(crm.doctypes.map((d) => d.qualified)).toEqual(['crm.Contact']);
			const hr = model.find((d) => d.id === 'hr')!;
			expect(hr.doctypes.map((d) => d.qualified)).toEqual(['hr.Employee']);
		});

		it('combines exact keys with the wildcard fallback', async () => {
			const driver = makeDriver();
			const model = await buildNavModel(driver, {
				'hr.Employee': ['read'],
				'*.*': ['update']
			});
			// The wildcard line lacks read → the crm doctypes stay hidden; the
			// exact key keeps Employee visible.
			expect(model.map((d) => d.id)).toEqual(['hr']);
		});

		it('keeps a doctype hidden when its exact key lacks read and it is excepted', async () => {
			const driver = makeDriver();
			const model = await buildNavModel(driver, {
				'*.*': ['read'],
				'crm.Company': ['update'],
				'*.*.except.read': ['crm.Company']
			});
			const crm = model.find((d) => d.id === 'crm')!;
			expect(crm.doctypes.map((d) => d.qualified)).toEqual(['crm.Contact']);
		});
	});

	describe('domain-wildcard visibility', () => {
		it('shows the hr domain when a domain-wildcard grant carries read', async () => {
			const driver = makeDriver();
			const model = await buildNavModel(driver, { 'hr.*': ['read'] });
			expect(model.map((d) => d.id)).toEqual(['hr']);
			const hr = model.find((d) => d.id === 'hr')!;
			expect(hr.doctypes.map((d) => d.qualified)).toEqual(['hr.Employee']);
		});

		it('does not let a *.*.except carve-out suppress a domain-wildcard grant', async () => {
			const driver = makeDriver();
			const model = await buildNavModel(driver, {
				'hr.*': ['read'],
				'*.*': ['read'],
				'*.*.except.read': ['hr.Employee']
			});
			const hr = model.find((d) => d.id === 'hr')!;
			expect(hr.doctypes.map((d) => d.qualified)).toEqual(['hr.Employee']);
		});
	});

	describe('preview carve-out', () => {
		beforeEach(() => clearPreviewSession());
		afterEach(() => clearPreviewSession());

		it('includes the bound draft in the live nav model when preview is active', async () => {
			// Without preview, the live nav model filters drafts out — the
			// `routes/[domain=notApi]/+page.ts` `domains.find` lookup would then
			// miss `_abc` and the live dashboard would 404 even though `apiFetch`
			// carries the Bearer token authorising the read. The preview carve-out
			// in `buildNavModel` exists to keep the bound draft visible.
			const driver = new MockDataDriver();
			driver.domain('core').doctype('Domain', [
				{ id: 'hr', color: '#FF0000' },
				{ id: '_abc', draft: true, name: 'Logistics' },
				{ id: '_xyz', draft: true, name: 'Other draft' }
			]);
			driver.registerDoctype('hr', 'Employee', {
				domain: 'hr',
				doctype: 'Employee',
				color: '#AAA',
				aggregate_root: true
			});
			driver.registerDoctype('_abc', 'Widget', {
				domain: '_abc',
				doctype: 'Widget',
				color: '#BBB',
				aggregate_root: true
			});

			setPreviewSession({
				draftId: '_abc',
				token: 'test-token',
				expiresAt: Math.floor(Date.now() / 1000) + 60
			});

			// `drafts` not set → defaults to `false` (the live path).
			const model = await buildNavModel(driver);

			const ids = model.map((d) => d.id).sort();
			// The bound draft `_abc` is included; the unbound draft `_xyz` is not.
			expect(ids).toEqual(['_abc', 'hr']);

			const abc = model.find((d) => d.id === '_abc')!;
			expect(abc.doctypes.map((d) => d.qualified)).toEqual(['_abc.Widget']);
			// The bound draft keeps its `(draft)` suffix so the sidebar timeline
			// shows the user that this entry is the in-preview draft.
			expect(abc.label).toBe('Logistics (draft)');
		});

		it('does not include any draft when preview is inactive', async () => {
			// Regression guard: the carve-out must not leak the bound draft when no
			// preview session is active — the live nav model still hides every draft.
			const driver = new MockDataDriver();
			driver.domain('core').doctype('Domain', [
				{ id: 'hr', color: '#FF0000' },
				{ id: '_abc', draft: true, name: 'Logistics' }
			]);
			driver.registerDoctype('hr', 'Employee', {
				domain: 'hr',
				doctype: 'Employee',
				color: '#AAA',
				aggregate_root: true
			});

			const model = await buildNavModel(driver);
			expect(model.map((d) => d.id)).toEqual(['hr']);
		});
	});
});

describe('navDoctypesForDomain', () => {
	it('returns the nav-visible doctypes of one domain from a registry snapshot', () => {
		const driver = makeDriver();
		const list = navDoctypesForDomain(driver, 'crm');
		expect(list.map((d) => d.qualified).sort()).toEqual(['crm.Company', 'crm.Contact']);
		expect(list.every((d) => d.pinned === false)).toBe(true);
	});

	it('applies the same child-visibility rule as buildNavModel', () => {
		const hidden = makeDriver();
		registerChild(hidden, { domain: 'crm', doctype: 'CompanyMembership', member_of: 'Company' });
		const hiddenTree = navDoctypesForDomain(hidden, 'crm');
		expect(hiddenTree.map((d) => d.qualified)).toEqual(['crm.Company', 'crm.Contact']);
		expect(hiddenTree[0].children?.map((d) => d.qualified)).toEqual(['crm.CompanyMembership']);

		const optIn = makeDriver();
		registerChild(optIn, {
			domain: 'crm',
			doctype: 'CompanyMembership',
			member_of: 'Company',
			nav_visible: true
		});
		const optInTree = navDoctypesForDomain(optIn, 'crm');
		const company = optInTree.find((d) => d.qualified === 'crm.Company')!;
		expect(company.children?.map((d) => d.qualified)).toContain('crm.CompanyMembership');
	});

	it('applies the optional visibility predicate and skips other domains', () => {
		const driver = makeDriver();
		expect(
			navDoctypesForDomain(driver, 'crm', (q) => q === 'crm.Company').map((d) => d.qualified)
		).toEqual(['crm.Company']);
		expect(navDoctypesForDomain(driver, 'hr').map((d) => d.qualified)).toEqual(['hr.Employee']);
	});

	it('returns [] for a domain with no definitions (fresh draft)', () => {
		const driver = makeDriver();
		expect(navDoctypesForDomain(driver, '_abc')).toEqual([]);
	});

	it('completes a preview dashboard NavDomain the way +page.ts composes it', () => {
		// B-171 regression guard: the preview dashboard's bespoke NavDomain came
		// from `domainProjectionToNavDomain` with a hardcoded `doctypes: []`, so
		// the dashboard showed "0 doctypes · 0 records" while the sidebar listed
		// the draft's doctypes. The route load now fills the list from the
		// registry via `navDoctypesForDomain`.
		const driver = new MockDataDriver();
		driver.domain('core').doctype('Domain', [{ id: '_abc', draft: true, name: 'Logistics' }]);
		driver.registerDoctype('_abc', 'Widget', {
			domain: '_abc',
			doctype: 'Widget',
			color: '#BBB',
			aggregate_root: true
		});

		const nav = domainProjectionToNavDomain({
			data: { draft: true, name: 'Logistics' },
			meta: { id: '_abc' }
		});
		expect(nav.doctypes).toEqual([]);

		nav.doctypes = navDoctypesForDomain(driver, '_abc');
		expect(nav.doctypes.map((d) => d.qualified)).toEqual(['_abc.Widget']);
	});
});
