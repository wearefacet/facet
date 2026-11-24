// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { createMockDriver } from '$lib/datasource/mock-seed.js';
import { loadDoctypeViews } from '$lib/doctype/loadDocumentView.js';

/**
 * Mock-seed contract for the view meta-doctypes.
 *
 * Seeds carry document/collection view rows as *children* (`meta.parent_id`),
 * while portable bundles carry the rest of the view set. The loader rewrites
 * seed child ids onto the mock driver's `{parent}.{rel}.*` prefix convention
 * and merges seed + bundle entities per doctype — `MockDomain.doctype()`
 * ignores seed data on later calls, so without the merge the two sources
 * would race for first-write-wins and lose rows.
 *
 * `core.Currency` doubles as the concrete case: its `view`, `form`, and
 * `quickView` templates are seeded (see `data/seeds/core.DocumentView/`),
 * and the bundle views of fixture doctypes (e.g. `crm.Company`) must survive
 * alongside them.
 */
interface ViewDocContent {
	kind?: string;
	template?: Record<string, unknown>;
	parent_doctype?: string;
}

describe('mock seed: document and collection views', () => {
	/** The seeded kind matrix — mirrors data/seeds/core.DocumentView/documents.yml. */
	const SEEDED_KINDS: Record<string, string[]> = {
		'iam.Account': ['form', 'quickView', 'view'],
		'iam.Roles': ['form', 'quickView', 'view'],
		'core.Webhook': ['form', 'quickView', 'view'],
		'core.DomainEditor': ['form', 'quickView', 'view'],
		'core.Domain': ['quickView', 'view'],
		'app.App': ['quickView', 'view'],
		'app.Deployment': ['quickView', 'view'],
		'iam.OIDCProvider': ['quickView', 'view'],
		'core.Currency': ['form', 'quickView', 'view'],
		'core.Comment': ['quickView']
	};

	it('serves the seeded currency views through the document_view child route', async () => {
		const driver = createMockDriver();
		const res = await driver
			.domain('core')
			.doctype('DocType')
			.doc('core.Currency')
			.children<ViewDocContent>('document_view')
			.list();

		const kinds = res.data.map((item) => item.data.kind).sort();
		expect(kinds).toEqual(['form', 'quickView', 'view']);

		const form = res.data.find((item) => item.data.kind === 'form');
		expect(form?.data.template?.type).toBe('col');
		expect(form?.data.parent_doctype).toBe('core.Currency');
	});

	it('keeps bundle views alongside the seeded ones', async () => {
		const driver = createMockDriver();
		const res = await driver
			.domain('core')
			.doctype('DocType')
			.doc('crm.Company')
			.children<ViewDocContent>('document_view')
			.list();

		const kinds = res.data.map((item) => item.data.kind);
		expect(kinds).toContain('view');
		expect(kinds).toContain('form');

		const views = await loadDoctypeViews(driver, 'crm.Company');
		expect(views.view).not.toBeNull();
	});

	it('loads the currency views through loadDoctypeViews', async () => {
		const driver = createMockDriver();
		const views = await loadDoctypeViews(driver, 'core.Currency');
		expect(views.view).not.toBeNull();
		expect(views.form).not.toBeNull();
		expect(views.quickView).not.toBeNull();
		expect(views.card).toBeUndefined();
		expect(views.inline).toBeUndefined();
	});

	it('serves every seeded system-doctype view set through the child route', async () => {
		// The currency case generalises: each doctype in the seed matrix is
		// served its expected kinds through the document_view child route,
		// which is what loadDoctypeView(s) reads on the show/peek/form routes.
		const driver = createMockDriver();
		for (const [parent, expected] of Object.entries(SEEDED_KINDS)) {
			const res = await driver
				.domain('core')
				.doctype('DocType')
				.doc(parent)
				.children<ViewDocContent>('document_view')
				.list();
			const kinds = res.data.map((item) => item.data.kind).sort();
			expect(kinds, parent).toEqual([...expected].sort());
		}
	});

	it('loads the seeded account views through loadDoctypeViews', async () => {
		const driver = createMockDriver();
		const views = await loadDoctypeViews(driver, 'iam.Account');
		expect(views.view).not.toBeNull();
		expect(views.form).not.toBeNull();
		expect(views.quickView).not.toBeNull();
	});
});
