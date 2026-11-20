// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import {
	assemblePaletteGroups,
	filterPaletteGroups,
	paletteGroupLabel,
	type AssemblePaletteInput,
	type PaletteCommand
} from './searchGroups.js';
import type { NavDomain } from '$lib/navTypes';
import type { RecentDocument } from '$lib/recentDocuments.svelte';
import type { RecordEntry } from './searchRecords.js';

const domains: NavDomain[] = [
	{
		id: 'crm',
		label: 'CRM',
		color: '#3F51B5',
		doctypes: [
			{ qualified: 'crm.Company', label: 'Company', color: '#3F51B5', icon: 'building-2' },
			{ qualified: 'crm.Contact', label: 'Contact', color: '#1B5E20', icon: null }
		]
	},
	{
		id: 'hr',
		label: 'Human Resources',
		color: '#E91E63',
		doctypes: [{ qualified: 'hr.Employee', label: 'Employee', color: '#E91E63' }]
	}
];

const recents: RecentDocument[] = [
	{ id: 'crm.Company.1', domain: 'crm', doctype: 'Company', ts: 3 },
	{ id: 'crm.Company.2', domain: 'crm', doctype: 'Company', ts: 2 }
];

const commands: PaletteCommand[] = [
	{ id: 'app.sidebar', label: 'Toggle sidebar', run: () => {} },
	{ id: 'app.help', label: 'Shortcuts', group: 'Help', icon: 'keyboard', run: () => {} }
];

const records: RecordEntry[] = [
	{
		key: 'crm.Company.crm.Company.1',
		domain: 'crm',
		doctype: 'Company',
		id: 'crm.Company.1',
		label: 'Acme Corp',
		subtitle: 'CompanyMembership · Bronze plan'
	},
	{
		key: 'hr.Employee.hr.Employee.7',
		domain: 'hr',
		doctype: 'Employee',
		id: 'hr.Employee.7',
		label: 'Alice',
		subtitle: null
	}
];

function input(overrides?: Partial<AssemblePaletteInput>): AssemblePaletteInput {
	return {
		domains,
		activeDomain: 'crm',
		recents,
		recentLabels: { 'crm.Company.1': 'Acme Corp' },
		commands,
		records,
		scope: 'domain',
		query: 'acme',
		...overrides
	};
}

describe('assemblePaletteGroups', () => {
	it('emits the four groups in order', () => {
		const groups = assemblePaletteGroups(input());
		expect(groups.map((g) => g.id)).toEqual(['navigate', 'recent', 'records', 'actions']);
	});

	it('builds Navigate from the domains, then the active domain’s doctypes', () => {
		const navigate = assemblePaletteGroups(input()).find((g) => g.id === 'navigate');
		expect(navigate?.entries.map((e) => e.label)).toEqual([
			'CRM',
			'Human Resources',
			'Company',
			'Contact'
		]);
		expect(navigate?.entries[2]).toMatchObject({
			kind: 'doctype',
			domain: 'crm',
			doctype: 'Company',
			tag: 'crm.Company',
			color: '#3F51B5',
			icon: 'building-2'
		});
	});

	it('skips doctype rows when no domain is active', () => {
		const navigate = assemblePaletteGroups(input({ activeDomain: '' })).find(
			(g) => g.id === 'navigate'
		);
		expect(navigate?.entries.map((e) => e.kind)).toEqual(['domain', 'domain']);
	});

	it('labels recents from the resolved map, falling back to the id', () => {
		const recent = assemblePaletteGroups(input()).find((g) => g.id === 'recent');
		expect(recent?.entries.map((e) => e.label)).toEqual(['Acme Corp', 'crm.Company.2']);
		expect(recent?.entries[0]).toMatchObject({
			kind: 'recent',
			domain: 'crm',
			doctype: 'Company',
			id: 'crm.Company.1',
			color: '#3F51B5'
		});
	});

	it('leaves recents unmarked when the nav model does not know the doctype', () => {
		const recent = assemblePaletteGroups(input({ domains: [] })).find((g) => g.id === 'recent');
		expect(recent?.entries[0]?.color ?? null).toBeNull();
	});

	it('carries record rows with their root anchor and subtitle', () => {
		const recordsGroup = assemblePaletteGroups(input()).find((g) => g.id === 'records');
		expect(recordsGroup?.entries[0]).toMatchObject({
			kind: 'record',
			domain: 'crm',
			doctype: 'Company',
			id: 'crm.Company.1',
			label: 'Acme Corp',
			subtitle: 'CompanyMembership · Bronze plan',
			tag: 'Company'
		});
	});

	it('qualifies record tags with the domain when the scope is app-wide', () => {
		const recordsGroup = assemblePaletteGroups(input({ scope: 'app' })).find(
			(g) => g.id === 'records'
		);
		expect(recordsGroup?.entries[0]?.tag).toBe('crm · Company');
		expect(recordsGroup?.entries[1]?.tag).toBe('hr · Employee');
	});

	it('appends the escalation row in domain scope, with the query echoed', () => {
		const recordsGroup = assemblePaletteGroups(input()).find((g) => g.id === 'records');
		const last = recordsGroup?.entries.at(-1);
		expect(last?.kind).toBe('escalate');
		expect(last?.label).toContain('acme');
		expect(last?.query).toBe('acme');
	});

	it('omits the escalation row in app-wide scope', () => {
		const recordsGroup = assemblePaletteGroups(input({ scope: 'app' })).find(
			(g) => g.id === 'records'
		);
		expect(recordsGroup?.entries.at(-1)?.kind).toBe('record');
	});

	it('keeps the escalation row in domain scope when the search found nothing', () => {
		const recordsGroup = assemblePaletteGroups(input({ records: [], query: 'cafe' })).find(
			(g) => g.id === 'records'
		);
		expect(recordsGroup?.entries).toHaveLength(1);
		expect(recordsGroup?.entries[0]).toMatchObject({ kind: 'escalate', query: 'cafe' });
	});

	it('carries host commands into Actions with their group hint and icon', () => {
		const actions = assemblePaletteGroups(input()).find((g) => g.id === 'actions');
		expect(actions?.entries[0]).toMatchObject({ kind: 'action', label: 'Toggle sidebar' });
		expect(actions?.entries[1]).toMatchObject({ tag: 'Help', icon: 'keyboard' });
	});
});

describe('empty states', () => {
	it('drops groups with no rows', () => {
		const groups = assemblePaletteGroups(
			input({
				domains: [],
				recents: [],
				records: [],
				commands: [],
				activeDomain: '',
				scope: 'app'
			})
		);
		expect(groups).toEqual([]);
	});

	it('keeps Navigate when only recents and records are empty', () => {
		const groups = assemblePaletteGroups(input({ recents: [], records: [] }));
		// The escalation row still fills Records in domain scope.
		expect(groups.map((g) => g.id)).toEqual(['navigate', 'records', 'actions']);
	});

	it('keeps Actions when only the nav model is empty', () => {
		const groups = assemblePaletteGroups(input({ domains: [], recents: [] }));
		expect(groups.map((g) => g.id)).toEqual(['records', 'actions']);
	});
});

describe('filterPaletteGroups', () => {
	it('matches Navigate, Recent, and Actions on a case-insensitive label substring', () => {
		const groups = filterPaletteGroups(assemblePaletteGroups(input()), 'COMP');
		expect(groups.map((g) => g.id)).toEqual(['navigate', 'recent', 'records']);
		const navigate = groups.find((g) => g.id === 'navigate');
		expect(navigate?.entries.map((e) => e.label)).toEqual(['Company']);
	});

	it('keeps the whole Navigate group when only a domain matches', () => {
		const groups = filterPaletteGroups(assemblePaletteGroups(input()), 'human');
		const navigate = groups.find((g) => g.id === 'navigate');
		expect(navigate?.entries.map((e) => e.label)).toEqual(['Human Resources']);
	});

	it('passes the records group through unfiltered — the server matched it', () => {
		const groups = filterPaletteGroups(assemblePaletteGroups(input()), 'zzz');
		// Navigate/Recent/Actions hold no 'zzz' label; Records survive intact.
		expect(groups.map((g) => g.id)).toEqual(['records']);
		expect(groups[0]?.entries).toHaveLength(3); // two records + escalation
	});

	it('keeps the escalation row — its label embeds the query', () => {
		const groups = filterPaletteGroups(assemblePaletteGroups(input()), 'acme');
		const recordsGroup = groups.find((g) => g.id === 'records');
		expect(recordsGroup?.entries.at(-1)?.kind).toBe('escalate');
	});

	it('returns every group for an empty query', () => {
		const groups = filterPaletteGroups(assemblePaletteGroups(input()), '   ');
		expect(groups.map((g) => g.id)).toEqual(['navigate', 'recent', 'records', 'actions']);
	});
});

describe('paletteGroupLabel', () => {
	it('resolves a label for each group id', () => {
		for (const id of ['navigate', 'recent', 'records', 'actions'] as const) {
			expect(paletteGroupLabel(id).length).toBeGreaterThan(0);
		}
	});
});
