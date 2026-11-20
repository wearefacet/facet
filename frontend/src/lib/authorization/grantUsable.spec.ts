// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it } from 'vitest';
import { missingRequiredActions, rolePermissionsFromContent, roleUsable } from './grantUsable.js';
import type { GrantInput, RolePermissionInput } from './grantUsable.js';

/**
 * Port of `spec/rbac/grant_resolver_spec.cr` — the `role_usable?` and
 * `missing_required_actions` describe blocks, plus the wire-shape helpers.
 * Each case keeps the backend fixture values so the two suites show the
 * same inputs and the same answers.
 */

/** Mirror of the Crystal `rbac_perm(action, on)` helper. */
const perm = (action: string, on: string): RolePermissionInput => ({ action, on });

/** Mirror of the Crystal `app_scope(grants_json)` helper. */
const grants = (...entries: GrantInput[]): GrantInput[] => entries;

const readContactGrant = { target: 'crm.Contact', actions: [{ name: 'read', required: true }] };

describe('missingRequiredActions / roleUsable', () => {
	it('is empty and usable when the role covers every required action', () => {
		const g = grants(readContactGrant);
		expect(missingRequiredActions(g, [perm('read', 'crm.Contact')])).toEqual([]);
		expect(roleUsable(g, [perm('read', 'crm.Contact')])).toBe(true);
	});

	it('names a missing required action and its grant target', () => {
		const g = grants({
			target: 'fin.Invoice',
			actions: [{ name: 'read', required: true }]
		});
		expect(missingRequiredActions(g, [perm('create', 'fin.Invoice')])).toEqual([
			'read on fin.Invoice'
		]);
		expect(roleUsable(g, [perm('create', 'fin.Invoice')])).toBe(false);
	});

	it('rejects the role when it misses one of two required actions', () => {
		const g = grants({
			target: 'crm.Contact',
			actions: [
				{ name: 'read', required: true },
				{ name: 'delete', required: true }
			]
		});
		expect(missingRequiredActions(g, [perm('read', 'crm.Contact')])).toEqual([
			'delete on crm.Contact'
		]);
	});

	it('rejects the role when it misses the target doctype entirely', () => {
		const g = grants(readContactGrant);
		expect(missingRequiredActions(g, [perm('read', 'crm.Other')])).toEqual(['read on crm.Contact']);
	});

	it('never rejects on optional actions', () => {
		const g = grants({
			target: 'crm.Contact',
			actions: [
				{ name: 'read', required: true },
				{ name: 'delete', required: false }
			]
		});
		expect(missingRequiredActions(g, [perm('read', 'crm.Contact')])).toEqual([]);
		expect(roleUsable(g, [])).toBe(false); // read is still required
		expect(
			roleUsable(
				grants({ target: 'crm.Contact', actions: [{ name: 'delete', required: false }] }),
				[]
			)
		).toBe(true);
	});

	it('is conjunctive across grant entries', () => {
		const g = grants(
			{ target: 'crm.Contact', actions: [{ name: 'read', required: true }] },
			{ target: 'crm.Pipeline', actions: [{ name: 'read', required: true }] }
		);
		expect(missingRequiredActions(g, [perm('read', 'crm.Contact')])).toEqual([
			'read on crm.Pipeline'
		]);
	});

	it('satisfies a domain-wildcard grant from one concrete role doctype', () => {
		const g = grants({ target: 'crm.*', actions: [{ name: 'read', required: true }] });
		expect(roleUsable(g, [perm('read', 'crm.Contact')])).toBe(true);
		expect(missingRequiredActions(g, [perm('read', 'iam.Account')])).toEqual(['read on crm.*']);
	});

	it('covers a required write grant only through create + update together', () => {
		const g = grants({ target: 'crm.Comment', actions: [{ name: 'write', required: true }] });
		expect(roleUsable(g, [perm('create', 'crm.Comment'), perm('update', 'crm.Comment')])).toBe(
			true
		);
		// Half-missing expansion: the role holds create, so the gap names update.
		expect(missingRequiredActions(g, [perm('create', 'crm.Comment')])).toEqual([
			'update on crm.Comment'
		]);
	});

	it('keeps the first required flag when write expands over an explicit action', () => {
		// create declared optional, then write required: create stays optional,
		// update is required — the backend dedupes with first-wins.
		const g = grants({
			target: 'crm.Comment',
			actions: [
				{ name: 'create', required: false },
				{ name: 'write', required: true }
			]
		});
		expect(missingRequiredActions(g, [perm('create', 'crm.Comment')])).toEqual([
			'update on crm.Comment'
		]);
		expect(roleUsable(g, [perm('create', 'crm.Comment'), perm('update', 'crm.Comment')])).toBe(
			true
		);
	});

	it('accepts the role `*` action as coverage for any required action', () => {
		const g = grants({ target: 'crm.Contact', actions: [{ name: 'delete', required: true }] });
		expect(roleUsable(g, [perm('*', 'crm.Contact')])).toBe(true);
	});

	it('accepts a role permission on a descendant path of the grant target', () => {
		const g = grants(readContactGrant);
		expect(roleUsable(g, [perm('read', 'crm.Contact.Comment')])).toBe(true);
		// The inverse does not hold: a grant on the child does not cover a
		// permission on the parent.
		expect(
			roleUsable(
				grants({ target: 'crm.Contact.Comment', actions: [{ name: 'read', required: true }] }),
				[perm('read', 'crm.Contact')]
			)
		).toBe(false);
	});

	it('accepts the wildcard role line (* on *.*) as coverage for any grant', () => {
		const g = grants(readContactGrant);
		expect(roleUsable(g, [perm('*', '*.*')])).toBe(true);
	});

	it('is usable with no required actions even with no permissions', () => {
		const g = grants({ target: 'crm.Contact', actions: [{ name: 'read', required: false }] });
		expect(roleUsable(g, [])).toBe(true);
		expect(missingRequiredActions(g, [])).toEqual([]);
	});

	it('is usable with no grants', () => {
		expect(roleUsable([], [])).toBe(true);
		expect(missingRequiredActions([], [perm('read', 'crm.Contact')])).toEqual([]);
	});

	it('lists every gap across entries when the role holds no permissions', () => {
		const g = grants(
			{ target: 'fin.Invoice', actions: [{ name: 'read', required: true }] },
			{ target: 'fin.Payment', actions: [{ name: 'read', required: true }] }
		);
		expect(missingRequiredActions(g, [])).toEqual(['read on fin.Invoice', 'read on fin.Payment']);
	});

	it('reports a duplicate grant target once', () => {
		const g = grants(readContactGrant, readContactGrant);
		expect(missingRequiredActions(g, [])).toEqual(['read on crm.Contact']);
	});

	it('ignores role lines that do not parse', () => {
		const g = grants(readContactGrant);
		expect(
			missingRequiredActions(g, [
				{ action: 'read', on: 'Contact' },
				{ action: 'read', on: 'crm' }
			])
		).toEqual(['read on crm.Contact']);
	});

	it('refuses a line whose except carve-out covers the concrete grant target', () => {
		// Mirror of the viewer line: read on *.* except core.SystemSettings.
		// Enforcement refuses the carved-out doctype outright; the port must
		// refuse it too.
		const g = grants({
			target: 'core.SystemSettings',
			actions: [{ name: 'read', required: true }]
		});
		const viewer: RolePermissionInput = {
			action: 'read',
			on: '*.*',
			except: ['core.SystemSettings', 'iam.OIDCProvider']
		};
		expect(roleUsable(g, [viewer])).toBe(false);
		expect(missingRequiredActions(g, [viewer])).toEqual(['read on core.SystemSettings']);
	});

	it('accepts a line whose except list carves only other doctypes', () => {
		const g = grants(readContactGrant);
		const viewer: RolePermissionInput = {
			action: 'read',
			on: '*.*',
			except: ['core.SystemSettings', 'iam.OIDCProvider']
		};
		expect(roleUsable(g, [viewer])).toBe(true);
	});

	it('applies the except prefix rule against descendant grant targets', () => {
		// except core.DocType also carves core.DocType.Comment (prefix rule,
		// same as enforcement).
		const childGrant = grants({
			target: 'core.DocType.Comment',
			actions: [{ name: 'read', required: true }]
		});
		expect(roleUsable(childGrant, [{ action: 'read', on: '*.*', except: ['core.DocType'] }])).toBe(
			false
		);

		// An entry on a descendant only leaves the parent grant covered.
		const parentGrant = grants({
			target: 'core.DocType',
			actions: [{ name: 'read', required: true }]
		});
		expect(
			roleUsable(parentGrant, [{ action: 'read', on: '*.*', except: ['core.DocType.Comment'] }])
		).toBe(true);
	});

	it('accepts an admin line without carve-outs against a concrete grant', () => {
		const g = grants({
			target: 'core.SystemSettings',
			actions: [{ name: 'read', required: true }]
		});
		expect(roleUsable(g, [perm('*', '*.*')])).toBe(true);
	});

	it('keeps the lenient reading for a wildcard grant target', () => {
		// A domain.* grant is satisfiable when at least one doctype survives
		// the carve-out (authoring refuses wildcard targets; the port stays
		// tolerant of content that reaches it without the gate).
		const g = grants({ target: 'crm.*', actions: [{ name: 'read', required: true }] });
		expect(roleUsable(g, [{ action: 'read', on: '*.*', except: ['crm.Secret'] }])).toBe(true);
	});
});

describe('rolePermissionsFromContent', () => {
	it('keeps the permission lines with string action and on', () => {
		expect(
			rolePermissionsFromContent({
				name: 'editor',
				permissions: [
					{ action: 'read', on: 'crm.Contact' },
					{ action: 'update', on: 'crm.Contact', scope: ['$mine'] },
					{ action: '*' },
					null,
					'action without on'
				]
			})
		).toEqual([
			{ action: 'read', on: 'crm.Contact' },
			{ action: 'update', on: 'crm.Contact', scope: ['$mine'] }
		]);
	});

	it('reads an absent permissions field as no lines', () => {
		expect(rolePermissionsFromContent({ name: 'empty' })).toEqual([]);
		expect(rolePermissionsFromContent(undefined)).toEqual([]);
	});
});
