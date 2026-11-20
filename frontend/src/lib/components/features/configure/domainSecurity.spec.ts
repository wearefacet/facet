// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it } from 'vitest';
import {
	composeContextSets,
	contextSetRowsFromMap,
	grantFieldOptions,
	isWildcard,
	pruneGrantFields,
	wildcardFieldsError,
	type ContextSetRow,
	type Grant
} from './domainSecurity.js';

function makeGrant(fields: string[] | string, doctype = ''): Grant {
	return { to: 'hr', doctype, fields };
}

describe('isWildcard', () => {
	it('is true only for the string wildcard', () => {
		expect(isWildcard(makeGrant('*'))).toBe(true);
	});

	it('is false for explicit field lists, including the empty list', () => {
		expect(isWildcard(makeGrant([]))).toBe(false);
		expect(isWildcard(makeGrant(['name', 'status']))).toBe(false);
	});
});

describe('wildcardFieldsError', () => {
	it('flags an array that mixes "*" with explicit names', () => {
		const err = wildcardFieldsError(makeGrant(['*', 'name']));
		expect(err).toBeTruthy();
		expect(err).toContain("'*'");
	});

	it('accepts a lone "*" inside an array (not combined with names)', () => {
		expect(wildcardFieldsError(makeGrant(['*']))).toBeUndefined();
	});

	it('accepts plain explicit names', () => {
		expect(wildcardFieldsError(makeGrant(['name', 'status']))).toBeUndefined();
	});

	it('accepts the wildcard string form (handled by the checkbox, not an error)', () => {
		expect(wildcardFieldsError(makeGrant('*'))).toBeUndefined();
	});
});

describe('grantFieldOptions', () => {
	const defs = [
		{ doctype: 'Project', fields: [{ key: 'name' }, { key: 'status' }, { key: 'owner_id' }] },
		{ doctype: 'Team', fields: [{ key: 'title' }] }
	];

	it('returns no options until a doctype is chosen', () => {
		expect(grantFieldOptions(defs, makeGrant([], ''))).toEqual([]);
	});

	it('maps the selected doctype field keys to options', () => {
		expect(grantFieldOptions(defs, makeGrant([], 'Project'))).toEqual([
			{ value: 'name', label: 'name' },
			{ value: 'status', label: 'status' },
			{ value: 'owner_id', label: 'owner_id' }
		]);
	});

	it('returns no options for a doctype outside the defs', () => {
		expect(grantFieldOptions(defs, makeGrant([], 'Invoice'))).toEqual([]);
	});
});

describe('pruneGrantFields', () => {
	const options = [
		{ value: 'name', label: 'name' },
		{ value: 'status', label: 'status' }
	];

	it('drops names the new schema no longer has and keeps survivor order', () => {
		const g = makeGrant(['status', 'owner_id', 'name']);
		pruneGrantFields(g, options);
		expect(g.fields).toEqual(['status', 'name']);
	});

	it('empties the list when the new schema has no fields, but keeps it a list', () => {
		const g = makeGrant(['name']);
		pruneGrantFields(g, []);
		expect(g.fields).toEqual([]);
	});

	it('leaves a wildcard grant untouched', () => {
		const g = makeGrant('*');
		pruneGrantFields(g, options);
		expect(g.fields).toBe('*');
	});
});

describe('contextSetRowsFromMap', () => {
	it('returns no rows for a missing or empty map', () => {
		expect(contextSetRowsFromMap(undefined)).toEqual([]);
		expect(contextSetRowsFromMap({})).toEqual([]);
	});

	it('builds one row per map entry, defaulting missing parts', () => {
		const rows = contextSetRowsFromMap({
			my_teams: { from: 'TeamMember', select: '$parent_id', where: { account: '$self' } },
			empty_set: { from: '', select: '', where: {} }
		});
		expect(rows).toHaveLength(2);
		expect(rows[0]).toEqual({
			name: 'my_teams',
			from: 'TeamMember',
			select: '$parent_id',
			where: [{ key: 'account', value: '$self' }]
		});
		// A def with holes (runtime data may carry undefined parts) still yields
		// an editable row with empty fallbacks.
		const partial = contextSetRowsFromMap({
			s: { from: 'A', select: undefined, where: undefined } as never
		});
		expect(partial[0]).toEqual({ name: 's', from: 'A', select: '', where: [] });
	});
});

describe('composeContextSets', () => {
	it('round-trips a map through rows back to the same map', () => {
		const map = {
			my_teams: { from: 'TeamMember', select: '$parent_id', where: { account: '$self' } }
		};
		const rows: ContextSetRow[] = contextSetRowsFromMap(map);
		expect(composeContextSets(rows)).toEqual(map);
	});

	it('drops rows without a name', () => {
		const rows: ContextSetRow[] = [
			{ name: '', from: 'A', select: '', where: [] },
			{ name: 'kept', from: 'B', select: '', where: [] }
		];
		expect(composeContextSets(rows)).toEqual({
			kept: { from: 'B', select: '', where: {} }
		});
	});

	it('drops where entries without a key', () => {
		const rows: ContextSetRow[] = [
			{
				name: 's',
				from: 'A',
				select: '',
				where: [
					{ key: '', value: '$self' },
					{ key: 'account', value: '$self' }
				]
			}
		];
		expect(composeContextSets(rows)).toEqual({
			s: { from: 'A', select: '', where: { account: '$self' } }
		});
	});

	it('returns an empty map for no rows', () => {
		expect(composeContextSets([])).toEqual({});
	});
});
