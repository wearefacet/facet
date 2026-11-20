// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect, vi } from 'vitest';
import { loadDoctypeCatalogue } from './doctypeCatalogue.js';

/**
 * Regression tests for the draft-domain leak: a doctype that belongs to a
 * draft domain (the builder's work in progress) must never reach the app
 * catalogue, so the app wizard's domain rail cannot show it and the grants
 * editor cannot select it.
 */

type Row = { data: Record<string, unknown>; meta: { id: string } };

function listResponse(rows: Row[]): Response {
	return new Response(JSON.stringify({ data: rows, meta: { count: rows.length, more: false } }), {
		status: 200,
		headers: { 'Content-Type': 'application/json' }
	});
}

const DOMAINS: Row[] = [
	{ data: { name: 'CRM' }, meta: { id: 'crm' } },
	{ data: { name: 'Human resources' }, meta: { id: 'hr' } },
	{ data: { name: 'Logistics', draft: true }, meta: { id: '_draft01' } }
];

const DOCTYPES: Row[] = [
	{ data: { doctype: 'Company', domain: 'crm' }, meta: { id: 'crm.Company' } },
	{ data: { doctype: 'Employee', domain: 'hr' }, meta: { id: 'hr.Employee' } },
	{ data: { doctype: 'Shipment', domain: '_draft01' }, meta: { id: '_draft01.Shipment' } },
	{ data: { doctype: 'Carrier', domain: '_draft01' }, meta: { id: '_draft01.Carrier' } }
];

/** Answers the `core.Domain` and `core.DocType` collection reads. */
function stubFetch(domains: Row[], doctypes: Row[]): typeof fetch {
	return vi.fn(async (input: string | URL | Request) => {
		const url = typeof input === 'string' ? input : input.toString();
		if (url.startsWith('/Api/core/Domain')) return listResponse(domains);
		if (url.startsWith('/Api/core/DocType')) return listResponse(doctypes);
		return new Response(JSON.stringify({ error: 'not stubbed' }), {
			status: 404,
			headers: { 'Content-Type': 'application/json' }
		});
	}) as unknown as typeof fetch;
}

describe('loadDoctypeCatalogue', () => {
	it('drops the doctypes of a draft domain', async () => {
		const { entries, metas } = await loadDoctypeCatalogue(stubFetch(DOMAINS, DOCTYPES));

		expect(entries.map((e) => e.target)).toEqual(['crm.Company', 'hr.Employee']);
		expect(entries.some((e) => e.domain === '_draft01')).toBe(false);
		expect(metas['_draft01.Shipment']).toBeUndefined();
	});

	it('keeps every live domain, including one with no draft flag', async () => {
		// `draft` absent (undefined) is a live domain — only an explicit
		// `draft: true` marks a draft. A missing flag must not hide a domain.
		const { entries } = await loadDoctypeCatalogue(
			stubFetch(
				[{ data: { name: 'Core' }, meta: { id: 'core' } }],
				[{ data: { doctype: 'Domain', domain: 'core' }, meta: { id: 'core.Domain' } }]
			)
		);

		expect(entries.map((e) => e.target)).toEqual(['core.Domain']);
	});

	it('reads both collections once', async () => {
		const fetchFn = stubFetch(DOMAINS, DOCTYPES);
		await loadDoctypeCatalogue(fetchFn);

		const urls = vi
			.mocked(fetchFn)
			.mock.calls.map(([input]) => (typeof input === 'string' ? input : input.toString()));
		expect(urls.filter((u) => u.startsWith('/Api/core/Domain'))).toHaveLength(1);
		expect(urls.filter((u) => u.startsWith('/Api/core/DocType'))).toHaveLength(1);
	});
});
