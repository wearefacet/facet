// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import {
	assignRole,
	unassignRole,
	roleDocIdToName,
	humanizeRoleName,
	hasRole,
	dedupeRoleIds
} from './roleMembership.js';

describe('roleMembership — dedupeRoleIds', () => {
	it('leaves a duplicate-free array unchanged', () => {
		expect(dedupeRoleIds(['iam.Roles.admin', 'iam.Roles.viewer'])).toEqual([
			'iam.Roles.admin',
			'iam.Roles.viewer'
		]);
	});

	it('collapses duplicates, preserving first-occurrence order', () => {
		expect(dedupeRoleIds(['iam.Roles.admin', 'iam.Roles.viewer', 'iam.Roles.admin'])).toEqual([
			'iam.Roles.admin',
			'iam.Roles.viewer'
		]);
	});

	it('returns an empty array when given an empty array', () => {
		expect(dedupeRoleIds([])).toEqual([]);
	});
});

describe('roleMembership — assignRole', () => {
	it('appends the role id when not present', () => {
		expect(assignRole([], 'iam.Roles.admin').roles).toEqual(['iam.Roles.admin']);
	});

	it('collapses a duplicate before appending', () => {
		const r = assignRole(['iam.Roles.admin', 'iam.Roles.admin'], 'iam.Roles.viewer');
		expect(r.roles).toEqual(['iam.Roles.admin', 'iam.Roles.viewer']);
	});

	it('sets the new role as default when the account had no roles', () => {
		const r = assignRole([], 'iam.Roles.admin');
		expect(r.defaultRole).toBe('iam.Roles.admin');
	});

	it('does not change default_role when an existing default is set', () => {
		const r = assignRole(['iam.Roles.viewer'], 'iam.Roles.admin', 'iam.Roles.viewer');
		expect(r.roles).toEqual(['iam.Roles.viewer', 'iam.Roles.admin']);
		expect(r.defaultRole).toBeUndefined();
	});

	it('keeps default_role unset when the account already has other roles and no default', () => {
		// `defaultRole` is omitted (undefined) — the caller PATCHes only
		// `roles`; login falls back to the first assigned role.
		const r = assignRole(['iam.Roles.viewer'], 'iam.Roles.admin', null);
		expect(r.defaultRole).toBeUndefined();
		expect(r.roles).toEqual(['iam.Roles.viewer', 'iam.Roles.admin']);
	});

	it('is idempotent — adding an already-assigned role leaves the array unchanged', () => {
		const r = assignRole(['iam.Roles.admin'], 'iam.Roles.admin', 'iam.Roles.admin');
		expect(r.roles).toEqual(['iam.Roles.admin']);
		expect(r.defaultRole).toBeUndefined();
	});
});

describe('roleMembership — unassignRole', () => {
	it('removes the role from the array', () => {
		expect(unassignRole(['iam.Roles.admin', 'iam.Roles.viewer'], 'iam.Roles.admin').roles).toEqual([
			'iam.Roles.viewer'
		]);
	});

	it('re-points default_role to the first remaining role when the default is removed', () => {
		const r = unassignRole(
			['iam.Roles.admin', 'iam.Roles.viewer'],
			'iam.Roles.admin',
			'iam.Roles.admin'
		);
		expect(r.roles).toEqual(['iam.Roles.viewer']);
		expect(r.defaultRole).toBe('iam.Roles.viewer');
	});

	it('clears default_role when the last role is removed', () => {
		const r = unassignRole(['iam.Roles.admin'], 'iam.Roles.admin', 'iam.Roles.admin');
		expect(r.roles).toEqual([]);
		expect(r.defaultRole).toBeNull();
	});

	it('does not emit defaultRole when the removed role was not the default', () => {
		const r = unassignRole(
			['iam.Roles.admin', 'iam.Roles.viewer'],
			'iam.Roles.viewer',
			'iam.Roles.admin'
		);
		expect(r.roles).toEqual(['iam.Roles.admin']);
		expect(r.defaultRole).toBeUndefined();
	});

	it('is a no-op when the role is not assigned', () => {
		const r = unassignRole(['iam.Roles.admin'], 'iam.Roles.viewer', 'iam.Roles.admin');
		expect(r.roles).toEqual(['iam.Roles.admin']);
		expect(r.defaultRole).toBeUndefined();
	});
});

describe('roleMembership — roleDocIdToName', () => {
	it('extracts the trailing segment', () => {
		expect(roleDocIdToName('iam.Roles.admin')).toBe('admin');
	});

	it('returns the input unchanged when there is no dot', () => {
		expect(roleDocIdToName('admin')).toBe('admin');
	});
});

describe('roleMembership — humanizeRoleName', () => {
	it('title-cases a single-word name', () => {
		expect(humanizeRoleName('admin')).toBe('Admin');
	});

	it('splits snake_case into title-cased words', () => {
		expect(humanizeRoleName('production_editor')).toBe('Production Editor');
	});

	it('collapses empty segments', () => {
		expect(humanizeRoleName('_a__b_')).toBe('A B');
	});
});

describe('roleMembership — hasRole', () => {
	it('returns true when the role is present', () => {
		expect(hasRole(['iam.Roles.admin'], 'iam.Roles.admin')).toBe(true);
	});

	it('returns false when the role is absent', () => {
		expect(hasRole(['iam.Roles.viewer'], 'iam.Roles.admin')).toBe(false);
	});

	it('returns false when the field is not an array', () => {
		expect(hasRole(undefined, 'iam.Roles.admin')).toBe(false);
		expect(hasRole(null, 'iam.Roles.admin')).toBe(false);
		expect(hasRole({}, 'iam.Roles.admin')).toBe(false);
	});

	it('ignores non-string entries', () => {
		expect(hasRole([1, true, 'iam.Roles.admin'], 'iam.Roles.admin')).toBe(true);
	});
});
