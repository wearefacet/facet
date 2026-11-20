// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it } from 'vitest';
import {
	DEFAULT_TAG,
	composeResourceRows,
	grantDomainId,
	resourceRowsError,
	resourceRowsFrom,
	tagsInUse,
	ticketPullsUntagged,
	type GrantResourceEntry,
	type GrantTicket
} from './domainGrants.js';

describe('grantDomainId', () => {
	it('strips the qualified reference prefix', () => {
		expect(grantDomainId('core.Domain.acme')).toBe('acme');
	});

	it('passes a bare domain through', () => {
		expect(grantDomainId('acme')).toBe('acme');
	});

	it('returns empty for missing input', () => {
		expect(grantDomainId(undefined)).toBe('');
		expect(grantDomainId('')).toBe('');
	});
});

describe('resourceRowsFrom / composeResourceRows', () => {
	it('round-trips entries through working-copy rows', () => {
		const entries: GrantResourceEntry[] = [
			{ doctype: 'Person', tags: ['default', 'pii'] },
			{ doctype: 'Company', tags: ['finance'] }
		];
		const rows = resourceRowsFrom(entries);
		expect(rows).toEqual([
			{ doctype: 'Person', tags: 'default, pii' },
			{ doctype: 'Company', tags: 'finance' }
		]);
		expect(composeResourceRows(rows)).toEqual(entries);
	});

	it('drops rows without a doctype and dedupes tags on compose', () => {
		const rows = [
			{ doctype: '', tags: 'orphan' },
			{ doctype: 'Person', tags: 'default, pii, default,  ' }
		];
		expect(composeResourceRows(rows)).toEqual([{ doctype: 'Person', tags: ['default', 'pii'] }]);
	});

	it('seeds empty rows for absent entries', () => {
		expect(resourceRowsFrom(undefined)).toEqual([]);
	});
});

describe('resourceRowsError', () => {
	it('flags a row with a doctype but no tags', () => {
		const err = resourceRowsError([{ doctype: 'Person', tags: '' }]);
		expect(err).toBeTruthy();
	});

	it('flags a row with tags but no doctype', () => {
		const err = resourceRowsError([{ doctype: '', tags: 'default' }]);
		expect(err).toBeTruthy();
	});

	it('accepts complete rows and drops empty rows', () => {
		expect(resourceRowsError([{ doctype: 'Person', tags: 'default' }])).toBeUndefined();
		expect(resourceRowsError([{ doctype: '', tags: '' }])).toBeUndefined();
	});
});

describe('ticketPullsUntagged', () => {
	it('is true when any edge names the default tag', () => {
		const ticket: GrantTicket = {
			producer: 'crm',
			filed: true,
			active: false,
			dropped: false,
			edges: [
				{ doctype: 'Company', tags: ['finance'] },
				{ doctype: 'Deal', tags: [DEFAULT_TAG] }
			]
		};
		expect(ticketPullsUntagged(ticket)).toBe(true);
	});

	it('is false when every edge names only explicit tags', () => {
		const ticket: GrantTicket = {
			producer: 'crm',
			filed: false,
			active: true,
			dropped: false,
			edges: [{ doctype: 'Person', tags: ['contact', 'pii'] }]
		};
		expect(ticketPullsUntagged(ticket)).toBe(false);
	});
});

describe('tagsInUse', () => {
	it('collects the union of field tags across doctypes, sorted', () => {
		const defs = [
			{ fields: [{ tags: ['pii', 'default'] }, { tags: undefined }] },
			{ fields: [{ tags: ['contact'] }, {}] }
		];
		expect(tagsInUse(defs)).toEqual(['contact', 'default', 'pii']);
	});

	it('returns empty when no field carries tags', () => {
		expect(tagsInUse([{ fields: [{}] }, { fields: [] }])).toEqual([]);
	});
});
