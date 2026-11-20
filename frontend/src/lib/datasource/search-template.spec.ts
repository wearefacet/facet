// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { createMockDriver } from '$lib/datasource/mock-seed.js';
import { parseDoctypeDef } from '$lib/doctype/types.js';

describe('mock seed search templates', () => {
	it('surfaces the `search` template for crm.Company', () => {
		const driver = createMockDriver();
		const raw = driver.getDoctypeDefinition('crm.Company');
		expect(raw).toBeTruthy();
		const def = parseDoctypeDef(raw as Record<string, unknown>);
		expect(def.search).toEqual('{{ name }} {{ domain_name }}');
	});

	it('surfaces the `search` template for identity.Person', () => {
		const driver = createMockDriver();
		const raw = driver.getDoctypeDefinition('identity.Person');
		expect(raw).toBeTruthy();
		const def = parseDoctypeDef(raw as Record<string, unknown>);
		expect(def.search).toEqual('{{ full_name }} {{ email }}');
	});

	it('surfaces the `search` template for crm.Deal', () => {
		const driver = createMockDriver();
		const raw = driver.getDoctypeDefinition('crm.Deal');
		expect(raw).toBeTruthy();
		const def = parseDoctypeDef(raw as Record<string, unknown>);
		expect(def.search).toEqual('{{ title }} {{ value }}');
	});
});

describe('mock search filter contract (mirrors the D3 ruling — the template is the flag)', () => {
	it('the bare `search` key matches the template corpus', async () => {
		const driver = createMockDriver();
		const res = await driver
			.domain('crm')
			.doctype('Company')
			.list({ filters: { search: 'acme.com' } });
		expect(res.data.map((item) => item.data.name)).toContain('Acme Corp');
	});

	it('matches a term from any templated field, not only the display name', async () => {
		// The Company template is `{{ name }} {{ domain_name }}` — 'acme' only
		// appears in both, but the corpus join keeps either matchable.
		const driver = createMockDriver();
		const res = await driver
			.domain('crm')
			.doctype('Company')
			.list({ filters: { search: 'acme' } });
		expect(res.data.map((item) => item.data.name)).toContain('Acme Corp');
	});

	it('a template-less doctype matches nothing — no fallback corpus', async () => {
		// core.Currency declares no `search` template; its EUR row carries the
		// name 'Euro', which the removed fallback corpus would have matched.
		const driver = createMockDriver();
		const res = await driver
			.domain('core')
			.doctype('Currency')
			.list({ filters: { search: 'euro' } });
		expect(res.data).toEqual([]);
	});

	it('a suffixed `search__*` key matches nothing — not a production of the grammar', async () => {
		const driver = createMockDriver();
		for (const key of ['search__match', 'search__eq', 'search__starts_with']) {
			const res = await driver
				.domain('crm')
				.doctype('Company')
				.list({ filters: { [key]: 'acme.com' } });
			expect(res.data).toEqual([]);
		}
	});
});
