// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it, vi } from 'vitest';
import {
	createQueryDispatcher,
	pickerSearchUrl,
	shapePickerSearch,
	type SearchResponseLike
} from './referenceSearch.js';

/**
 * One contract-true hit: the wire carries `domain`/`doctype` on the group
 * only. The fixture sets the root anchor fields, never a per-hit domain or
 * doctype. A root hit anchors itself unless the test overrides the anchor;
 * the anchor doctype defaults to the `Company` fixture.
 */
const hit = (
	over: Partial<{
		id: string;
		display_name: string | null;
		root_doctype: string;
		root_id: string;
		root_display_name: string;
		child_label: string | null;
	}> = {},
	anchorDoctype = 'Company'
) => {
	const merged = {
		id: '01A',
		display_name: 'Acme',
		rank: 0.9,
		root_doctype: '',
		root_id: '',
		root_display_name: '',
		child_label: null,
		...over
	};
	if (!merged.root_doctype) merged.root_doctype = anchorDoctype;
	if (!merged.root_id) merged.root_id = merged.id;
	if (!merged.root_display_name) merged.root_display_name = merged.display_name ?? '';
	return merged;
};

const resp = (groups: { domain: string; doctype: string; hits: unknown[] }[]) =>
	({ data: groups, meta: { q: 'q', count: 1, scope: 'domain' } }) as SearchResponseLike;

describe('pickerSearchUrl', () => {
	it('builds the domain-scoped endpoint', () => {
		expect(pickerSearchUrl('ada lovelace', 'domain', 'hr')).toBe('/Api/hr/search?q=ada%20lovelace');
	});

	it('builds the app-wide endpoint', () => {
		expect(pickerSearchUrl('ada', 'app', 'hr')).toBe('/Api/search?q=ada');
	});
});

describe('shapePickerSearch', () => {
	it('groups hits per doctype in rank order', () => {
		const shaped = shapePickerSearch(
			resp([
				{ domain: 'crm', doctype: 'Company', hits: [hit({ id: '01A' }), hit({ id: '01B' })] },
				{ domain: 'hr', doctype: 'Employee', hits: [hit({ id: '01C' }, 'Employee')] }
			]),
			'crm'
		);
		expect(shaped.groups.map((g) => g.key)).toEqual(['crm.Company', 'hr.Employee']);
		expect(shaped.groups[0].entries.map((e) => e.id)).toEqual(['01A', '01B']);
		expect(shaped.accounts).toEqual([]);
	});

	it('inherits the group domain and doctype on every entry (B-119)', () => {
		// The wire contract carries `domain`/`doctype` at group level only —
		// the picker entry needs them to key its group and qualify references.
		const shaped = shapePickerSearch(
			resp([
				{ domain: 'crm', doctype: 'Company', hits: [hit({ id: '01A' })] },
				{ domain: 'hr', doctype: 'Employee', hits: [hit({ id: '01C' }, 'Employee')] }
			]),
			'crm'
		);
		expect(shaped.groups.map((g) => [g.domain, g.doctype])).toEqual([
			['crm', 'Company'],
			['hr', 'Employee']
		]);
		expect(shaped.groups[0].entries[0]).toMatchObject({ domain: 'crm', doctype: 'Company' });
		expect(shaped.groups[1].entries[0]).toMatchObject({ domain: 'hr', doctype: 'Employee' });
	});

	it('collapses child hits into their aggregate root', () => {
		const shaped = shapePickerSearch(
			resp([
				{
					domain: 'crm',
					doctype: 'Note',
					hits: [
						hit({
							id: '01N',
							display_name: 'Call notes',
							root_doctype: 'Company',
							root_id: '01A',
							root_display_name: 'Acme',
							child_label: 'Call notes'
						})
					]
				}
			]),
			'crm'
		);
		expect(shaped.groups).toHaveLength(1);
		expect(shaped.groups[0].doctype).toBe('Company');
		expect(shaped.groups[0].entries[0]).toMatchObject({
			id: '01A',
			label: 'Acme',
			// The subtitle names the child doctype inherited from the group.
			subtitle: 'Note · Call notes'
		});
	});

	it('lifts account hits out of the groups into the pinned accounts list', () => {
		const shaped = shapePickerSearch(
			resp([
				{
					domain: 'iam',
					doctype: 'Account',
					hits: [hit({ id: '01U', display_name: 'Ada' }, 'Account')]
				},
				{ domain: 'crm', doctype: 'Company', hits: [hit()] }
			]),
			'crm'
		);
		expect(shaped.accounts.map((a) => a.id)).toEqual(['01U']);
		expect(shaped.groups.map((g) => g.key)).toEqual(['crm.Company']);
	});

	it('orders the active domain first, then rank order — never reorders', () => {
		const shaped = shapePickerSearch(
			resp([
				{ domain: 'hr', doctype: 'Employee', hits: [hit({ id: '01C' }, 'Employee')] },
				{ domain: 'crm', doctype: 'Company', hits: [hit()] }
			]),
			'crm'
		);
		expect(shaped.groups.map((g) => g.domain)).toEqual(['crm', 'hr']);
	});

	it('flags groups at the per-doctype cap', () => {
		const hits = Array.from({ length: 5 }, (_, i) => hit({ id: `01${i}` }));
		const shaped = shapePickerSearch(resp([{ domain: 'crm', doctype: 'Company', hits }]), 'crm');
		expect(shaped.groups[0].atCap).toBe(true);

		const shapedShort = shapePickerSearch(
			resp([{ domain: 'crm', doctype: 'Company', hits: hits.slice(0, 2) }]),
			'crm'
		);
		expect(shapedShort.groups[0].atCap).toBe(false);
	});

	it('drops a group whose domain is missing or malformed, keeping the rest (B-119)', () => {
		// A group without a usable domain cannot anchor an entry to a page the
		// app can open — shaping degrades by dropping it, never by throwing.
		const data = [
			{ doctype: 'Company', hits: [hit({ id: '01A' })] },
			{ domain: 42, doctype: 'Company', hits: [hit({ id: '01B' })] },
			{ domain: 'hr', doctype: 'Employee', hits: [hit({ id: '01C' }, 'Employee')] }
		] as unknown as SearchResponseLike['data'];
		const shaped = shapePickerSearch(
			{ data, meta: { q: 'q', count: 3, scope: 'domain' } } as SearchResponseLike,
			'crm'
		);
		expect(shaped.groups).toHaveLength(1);
		expect(shaped.groups[0]).toMatchObject({ domain: 'hr', doctype: 'Employee' });
		expect(shaped.groups[0].entries.map((e) => e.id)).toEqual(['01C']);
		expect(shaped.accounts).toEqual([]);
	});

	it('tolerates an absent data array', () => {
		const shaped = shapePickerSearch({ data: null } as unknown as SearchResponseLike, 'crm');
		expect(shaped.groups).toEqual([]);
		expect(shaped.accounts).toEqual([]);
	});
});

describe('createQueryDispatcher', () => {
	it('debounces bursts into one run', async () => {
		vi.useFakeTimers();
		const run = vi.fn();
		const dispatcher = createQueryDispatcher(200, run);
		dispatcher.query('a');
		dispatcher.query('ab');
		dispatcher.query('abc');
		expect(run).not.toHaveBeenCalled();
		await vi.advanceTimersByTimeAsync(250);
		expect(run).toHaveBeenCalledTimes(1);
		expect(run).toHaveBeenCalledWith('abc', 3);
		vi.useRealTimers();
	});

	it('bumps the sequence on every call so stale completions discard', async () => {
		vi.useFakeTimers();
		const run = vi.fn();
		const dispatcher = createQueryDispatcher(200, run);
		dispatcher.query('first');
		await vi.advanceTimersByTimeAsync(250);
		expect(dispatcher.currentSeq()).toBe(1);
		dispatcher.query('second');
		expect(dispatcher.currentSeq()).toBe(2);
		await vi.advanceTimersByTimeAsync(250);
		expect(dispatcher.currentSeq()).toBe(2);
		vi.useRealTimers();
	});

	it('cancel drops the pending run', async () => {
		vi.useFakeTimers();
		const run = vi.fn();
		const dispatcher = createQueryDispatcher(200, run);
		dispatcher.query('q');
		dispatcher.cancel();
		await vi.advanceTimersByTimeAsync(400);
		expect(run).not.toHaveBeenCalled();
		expect(dispatcher.currentSeq()).toBe(2);
		vi.useRealTimers();
	});
});
