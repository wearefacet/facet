// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import {
	asDoctypeDef,
	buildTree,
	loadState,
	serializeState,
	scopeOptionsFor,
	roleOptions,
	descendantCount,
	filterTree,
	deriveExpandedKeys,
	actionsFor,
	actionDescription,
	CORE_ACTIONS,
	ALL_SCOPE,
	type DoctypeNode,
	type DomainTree
} from './rbacModel.js';

// ── Helpers ────────────────────────────────────────────────────────────────

function def(
	domain: string,
	doctype: string,
	overrides: Record<string, unknown> = {}
): Record<string, unknown> {
	return { domain, doctype, ...overrides };
}

const productionDefs = new Map<string, Record<string, unknown>>([
	[
		'production.Project',
		def('production', 'Project', {
			aggregate_root: true,
			fields: {
				name: { type: 'string' },
				team: { type: 'reference', reference_doctype: 'production.Team' }
			},
			scopes: {
				mine: { description: 'Projects owned by the actioner', where: { owner_id: '$self' } },
				active: { description: 'Active projects', where: { status: 'active' } }
			},
			children: {
				tasks: { doctype: 'Task', collection: true }
			}
		})
	],
	[
		'production.Task',
		def('production', 'Task', {
			member_of: 'Project',
			fields: { title: { type: 'string' }, assignee: { type: 'reference' } },
			scopes: { mine: { where: { assignee: '$self' } } }
		})
	],
	[
		'production.Team',
		def('production', 'Team', {
			aggregate_root: true,
			fields: { name: { type: 'string' } },
			children: {
				members: { doctype: 'TeamMember', collection: true }
			}
		})
	],
	[
		'production.TeamMember',
		def('production', 'TeamMember', {
			member_of: 'Team',
			fields: { account: { type: 'reference' } }
		})
	]
]);

// Backing defs with custom (named) actions, mirroring `crm.Deal`.
const crmDealDefs = new Map<string, Record<string, unknown>>([
	[
		'crm.Deal',
		def('crm', 'Deal', {
			aggregate_root: true,
			fields: { title: { type: 'string' } },
			scopes: { mine: { where: { owner_id: '$self' } } },
			actions: {
				move_stage: { args: { target_stage_id: { type: 'string', required: true } } },
				win: { args: { actual_close_date: { type: 'string', required: true } } },
				lose: { args: { reason: { type: 'string', required: true } } }
			}
		})
	]
]);

// ── asDoctypeDef ───────────────────────────────────────────────────────────

describe('asDoctypeDef', () => {
	it('keeps known keys and drops unknown ones', () => {
		const result = asDoctypeDef({
			domain: 'hr',
			doctype: 'Employee',
			aggregate_root: true,
			junk: 'ignored',
			fields: { name: { type: 'string' } },
			scopes: { mine: { description: 'mine', where: { id: '$self' } } }
		});
		expect(result.domain).toBe('hr');
		expect(result.doctype).toBe('Employee');
		expect(result.aggregate_root).toBe(true);
		expect(result.fields?.name.type).toBe('string');
		expect(result.scopes?.mine.where).toEqual({ id: '$self' });
	});

	it('defaults optional booleans to undefined when absent', () => {
		const result = asDoctypeDef(def('crm', 'Contact'));
		expect(result.aggregate_root).toBeUndefined();
		expect(result.member_of).toBeUndefined();
		expect(result.children).toBeUndefined();
		expect(result.fields).toBeUndefined();
		expect(result.scopes).toBeUndefined();
	});
});

// ── buildTree ───────────────────────────────────────────────────────────────

describe('buildTree', () => {
	it('partitions doctypes by domain', () => {
		const registry = new Map<string, Record<string, unknown>>([
			...productionDefs,
			['hr.Employee', def('hr', 'Employee', { aggregate_root: true })]
		]);
		const tree = buildTree(registry);
		const domains = tree.map((d) => d.domain);
		expect(domains).toContain('production');
		expect(domains).toContain('hr');
	});

	it('orders core/iam first, then alphabetical', () => {
		const tree = buildTree(
			new Map<string, Record<string, unknown>>([
				['zeta.Root', def('zeta', 'Root', { aggregate_root: true })],
				['core.Domain', def('core', 'Domain', { aggregate_root: true })],
				['iam.Account', def('iam', 'Account', { aggregate_root: true })],
				['alpha.Root', def('alpha', 'Root', { aggregate_root: true })]
			])
		);
		expect(tree.map((d) => d.domain)).toEqual(['core', 'iam', 'alpha', 'zeta']);
	});

	it('nests children declared via parent `children:`', () => {
		const tree = buildTree(productionDefs);
		const production = tree.find((d) => d.domain === 'production');
		expect(production?.roots.map((r) => r.doctype).sort()).toEqual(['Project', 'Team']);

		const project = production?.roots.find((r) => r.doctype === 'Project');
		expect(project?.children.map((c) => c.doctype)).toEqual(['Task']);
		expect(project?.children[0].path).toEqual(['Project', 'Task']);
		expect(project?.children[0].depth).toBe(1);
	});

	it('nests children declared via child `member_of`', () => {
		const tree = buildTree(
			new Map<string, Record<string, unknown>>([
				['hr.Employee', def('hr', 'Employee', { aggregate_root: true })],
				[
					'hr.CareerEvent',
					def('hr', 'CareerEvent', {
						member_of: 'Employee',
						fields: { event_type: { type: 'string' } }
					})
				]
			])
		);
		const hr = tree.find((d) => d.domain === 'hr');
		const emp = hr?.roots.find((r) => r.doctype === 'Employee');
		expect(emp?.children.map((c) => c.doctype)).toEqual(['CareerEvent']);
	});

	it('does not double-count a child declared two ways', () => {
		const registry = new Map<string, Record<string, unknown>>([
			[
				'hr.Employee',
				def('hr', 'Employee', {
					aggregate_root: true,
					children: { career_events: { doctype: 'CareerEvent' } }
				})
			],
			['hr.CareerEvent', def('hr', 'CareerEvent', { member_of: 'Employee' })]
		]);
		const tree = buildTree(registry);
		const emp = tree[0].roots[0];
		expect(emp.children.length).toBe(1);
		expect(emp.children[0].doctype).toBe('CareerEvent');
	});

	it('handles orphan roots (no member_of, no children)', () => {
		const tree = buildTree(
			new Map([['crm.Contact', def('crm', 'Contact', { aggregate_root: true })]])
		);
		expect(tree[0].roots.map((r) => r.doctype)).toEqual(['Contact']);
	});

	it('respects aggregate_root=true', () => {
		const tree = buildTree(new Map([['a.Root', def('a', 'Root', { aggregate_root: true })]]));
		expect(tree[0].roots[0].doctype).toBe('Root');
	});

	it('breaks cycles safely (no infinite recursion)', () => {
		const registry = new Map<string, Record<string, unknown>>([
			['x.A', def('x', 'A', { member_of: 'B' })],
			['x.B', def('x', 'B', { member_of: 'A' })]
		]);
		expect(() => buildTree(registry)).not.toThrow();
	});
});

// ── descendantCount ────────────────────────────────────────────────────────

describe('descendantCount', () => {
	it('counts all transitive descendants', () => {
		const tree = buildTree(productionDefs);
		const project = tree
			.find((d) => d.domain === 'production')!
			.roots.find((r) => r.doctype === 'Project')!;
		expect(descendantCount(project)).toBe(1); // Task (no further children)
	});

	it('returns 0 for a leaf', () => {
		const tree = buildTree(productionDefs);
		const task = tree
			.find((d) => d.domain === 'production')!
			.roots.find((r) => r.doctype === 'Project')!.children[0];
		expect(descendantCount(task)).toBe(0);
	});
});

// ── loadState / serializeState round-trip ───────────────────────────────────

describe('loadState', () => {
	it('returns empty state for a role with no permissions', () => {
		expect(loadState({ name: 'empty', permissions: [] })).toEqual({});
	});

	it('returns empty state for undefined role', () => {
		expect(loadState(undefined)).toEqual({});
	});

	it('sets unrestricted when scope is absent', () => {
		const state = loadState({
			name: 'editor',
			permissions: [{ action: 'read', on: 'production.Project' }]
		});
		expect(state['production.Project'].read).toEqual([ALL_SCOPE]);
		expect(state['production.Project'].update).toEqual([]);
	});

	it('preserves the alias string for a named-scope permission', () => {
		const state = loadState({
			name: 'scoped',
			permissions: [{ action: 'read', on: 'production.Project', scope: ['$mine'] }]
		});
		expect(state['production.Project'].read).toEqual(['$mine']);
	});

	it('accepts the legacy single-string scope form', () => {
		// The wire form was previously a single string. We feed it through
		// `as unknown` because the typed `PermissionRaw.scope` is now an array;
		// `loadState` still accepts the legacy form at runtime.
		const legacy = [{ action: 'read', on: 'production.Project', scope: '$mine' }] as unknown as {
			action: string;
			on: string;
			scope?: string[];
		}[];
		const state = loadState({ name: 'legacy', permissions: legacy });
		expect(state['production.Project'].read).toEqual(['$mine']);
	});

	it('normalizes $all to [ALL_SCOPE]', () => {
		const state = loadState({
			name: 'explicit',
			permissions: [{ action: 'read', on: 'production.Project', scope: ['$all'] }]
		});
		expect(state['production.Project'].read).toEqual([ALL_SCOPE]);
	});

	it('preserves multiple aliases (OR semantics) on a single permission', () => {
		const state = loadState({
			name: 'or',
			permissions: [{ action: 'read', on: 'production.Project', scope: ['$mine', '$active'] }]
		});
		expect(state['production.Project'].read).toEqual(['$mine', '$active']);
	});

	it('keeps wildcard *.* lines so a save cannot drop them', () => {
		// B-350 — the editor renders no row for `*.*`, but a save rewrites the
		// whole `permissions` array. A dropped wildcard line silently widens or
		// destroys the role, so the lines must stay in the state.
		const state = loadState({
			name: 'viewer',
			permissions: [{ action: 'read', on: '*.*' }]
		});
		expect(state['*.*'].read).toEqual([ALL_SCOPE]);
		expect(serializeState(state)).toEqual([{ action: 'read', on: '*.*' }]);
	});

	it('preserves custom (named) actions', () => {
		// Custom actions like `promote` are valid permissions in the wire
		// format — they reference a named action declared on the doctype.
		const state = loadState({
			name: 'x',
			permissions: [{ action: 'promote', on: 'production.Project' }]
		});
		expect(state['production.Project'].promote).toEqual([ALL_SCOPE]);
		// Canonical four stay None when not granted.
		expect(state['production.Project'].read).toEqual([]);
	});

	it('merges multiple permission lines on the same path/action by union (OR)', () => {
		// The legacy wire form (two permission lines for the same action+on)
		// is preserved losslessly by unioning their scope aliases, so a role
		// authored before the array wire form still round-trips correctly.
		const state = loadState({
			name: 'multi',
			permissions: [
				{ action: 'read', on: 'production.Project', scope: ['$mine'] },
				{ action: 'read', on: 'production.Project', scope: ['$active'] }
			]
		});
		expect(state['production.Project'].read).toEqual(['$mine', '$active']);
	});

	it('collapses to [ALL_SCOPE] when merging lines if any is unrestricted', () => {
		const state = loadState({
			name: 'mixed',
			permissions: [
				{ action: 'read', on: 'production.Project', scope: ['$mine'] },
				{ action: 'read', on: 'production.Project' } // unrestricted
			]
		});
		expect(state['production.Project'].read).toEqual([ALL_SCOPE]);
	});
});

describe('serializeState', () => {
	it('omits None actions entirely', () => {
		const perms = serializeState({
			'production.Project': {
				read: [ALL_SCOPE],
				create: [],
				update: [],
				delete: []
			}
		});
		expect(perms).toEqual([{ action: 'read', on: 'production.Project' }]);
	});

	it('omits the scope key for All (unrestricted)', () => {
		const perms = serializeState({
			'production.Project': {
				read: [ALL_SCOPE],
				create: [],
				update: [],
				delete: []
			}
		});
		expect(perms[0].scope).toBeUndefined();
	});

	it('emits a single-alias scope as an array', () => {
		const perms = serializeState({
			'production.Project': {
				read: ['$mine'],
				create: [],
				update: [],
				delete: []
			}
		});
		expect(perms).toEqual([{ action: 'read', on: 'production.Project', scope: ['$mine'] }]);
	});

	it('emits a multi-alias scope as a single permission with the array', () => {
		const perms = serializeState({
			'production.Project': {
				read: ['$mine', '$active'],
				create: [],
				update: [],
				delete: []
			}
		});
		expect(perms).toEqual([
			{ action: 'read', on: 'production.Project', scope: ['$mine', '$active'] }
		]);
	});

	it('sorts by path then by action (read before update)', () => {
		const perms = serializeState({
			'production.Task': {
				read: [ALL_SCOPE],
				create: [],
				update: [ALL_SCOPE],
				delete: []
			},
			'production.Project': {
				read: [ALL_SCOPE],
				create: [],
				update: [ALL_SCOPE],
				delete: []
			}
		});
		expect(perms.map((p) => `${p.action} ${p.on}`)).toEqual([
			'read production.Project',
			'update production.Project',
			'read production.Task',
			'update production.Task'
		]);
	});

	// B-350 — a save rewrites the whole `permissions` array. The seeded roles
	// carry their `except` carve-outs on wildcard `*.*` lines; the editor has
	// no control for carve-outs, but a save must not strip them.
	it('keeps except carve-outs byte-identical when an unrelated row is edited', () => {
		const role = {
			name: 'editor',
			permissions: [
				{ action: 'create', on: '*.*', except: ['core.DocType', 'core.SystemSettings'] },
				{ action: 'update', on: '*.*', except: ['core.Domain', 'core.Webhook'] },
				{
					action: 'read',
					on: '*.*',
					except: ['core.SystemSettings', 'iam.OIDCProvider', 'core.Webhook']
				},
				{ action: 'update', on: 'core.Domain', scope: ['$domain_editor'] },
				{ action: 'read', on: 'core.Webhook', scope: ['$mine'] }
			]
		};
		const state = loadState(role);
		// Edit an unrelated doctype row — a fresh grant on core.Webhook.
		state['core.Webhook'].create = [ALL_SCOPE];
		expect(serializeState(state)).toEqual([
			{
				action: 'read',
				on: '*.*',
				except: ['core.SystemSettings', 'iam.OIDCProvider', 'core.Webhook']
			},
			{ action: 'create', on: '*.*', except: ['core.DocType', 'core.SystemSettings'] },
			{ action: 'update', on: '*.*', except: ['core.Domain', 'core.Webhook'] },
			{ action: 'update', on: 'core.Domain', scope: ['$domain_editor'] },
			{ action: 'read', on: 'core.Webhook', scope: ['$mine'] },
			{ action: 'create', on: 'core.Webhook' }
		]);
	});

	it('emits no except key when no line carries carve-outs', () => {
		const role = {
			name: 'plain',
			permissions: [
				{ action: 'read', on: 'production.Project' },
				{ action: 'read', on: '*.*' }
			]
		};
		expect(serializeState(loadState(role))).toEqual([
			{ action: 'read', on: '*.*' },
			{ action: 'read', on: 'production.Project' }
		]);
	});

	it('round-trips an except carve-out on a concrete path', () => {
		const role = {
			name: 'carved',
			permissions: [{ action: 'update', on: 'crm.Deal', except: ['crm.Deal.Secret'] }]
		};
		expect(serializeState(loadState(role))).toEqual([
			{ action: 'update', on: 'crm.Deal', except: ['crm.Deal.Secret'] }
		]);
	});

	it('folds same-action carve-outs by intersection (OR-over-lines semantics)', () => {
		// Backend grants OR their lines: a target stays excepted only when
		// every same-action line subtracts it — the same fold the backend
		// applies in IAM::Helpers.build_permission_manifest.
		const role = {
			name: 'folded',
			permissions: [
				{ action: 'read', on: '*.*', except: ['core.Webhook', 'core.SystemSettings'] },
				{ action: 'read', on: '*.*', except: ['core.Webhook'] }
			]
		};
		expect(serializeState(loadState(role))).toEqual([
			{ action: 'read', on: '*.*', except: ['core.Webhook'] }
		]);
	});

	it('clears the carve-out fold when a same-action line carries none', () => {
		// The except-free line grants the carved-out paths, so the merged line
		// must not keep the carve-out.
		const role = {
			name: 'dissolved',
			permissions: [
				{ action: 'read', on: '*.*', except: ['core.Webhook'] },
				{ action: 'read', on: '*.*' }
			]
		};
		expect(serializeState(loadState(role))).toEqual([{ action: 'read', on: '*.*' }]);
	});

	it('round-trips through loadState', () => {
		const role = {
			name: 'scoped',
			permissions: [
				{ action: 'read', on: 'production.Project' },
				{ action: 'update', on: 'production.Project', scope: ['$mine'] },
				{ action: 'read', on: 'production.Task', scope: ['$mine'] }
			]
		};
		const re = serializeState(loadState(role));
		expect(re).toEqual([
			{ action: 'read', on: 'production.Project' },
			{ action: 'update', on: 'production.Project', scope: ['$mine'] },
			{ action: 'read', on: 'production.Task', scope: ['$mine'] }
		]);
	});

	it('round-trips a multi-alias OR permission through loadState', () => {
		const role = {
			name: 'or',
			permissions: [{ action: 'read', on: 'production.Project', scope: ['$mine', '$active'] }]
		};
		const re = serializeState(loadState(role));
		expect(re).toEqual([{ action: 'read', on: 'production.Project', scope: ['$mine', '$active'] }]);
	});

	it('drops scope that was reverted to All (no leftover alias)', () => {
		const perms = serializeState({
			'production.Project': {
				read: [ALL_SCOPE], // was ['$mine'] before, user reverted to All
				create: [],
				update: [],
				delete: []
			}
		});
		expect(perms).toEqual([{ action: 'read', on: 'production.Project' }]);
	});

	it('emits canonical CRUD actions before custom ones for the same doctype', () => {
		const perms = serializeState({
			'crm.Deal': {
				read: [ALL_SCOPE],
				create: [],
				update: [],
				delete: [],
				move_stage: ['$mine'],
				win: [ALL_SCOPE],
				lose: []
			}
		});
		expect(
			perms.map((p) => `${p.action} ${p.on}${p.scope ? ' ' + JSON.stringify(p.scope) : ''}`)
		).toEqual(['read crm.Deal', 'move_stage crm.Deal ["$mine"]', 'win crm.Deal']);
	});

	it('round-trips custom actions through loadState', () => {
		const role = {
			name: 'deal_admin',
			permissions: [
				{ action: 'read', on: 'crm.Deal' },
				{ action: 'move_stage', on: 'crm.Deal', scope: ['$mine'] },
				{ action: 'win', on: 'crm.Deal' }
			]
		};
		const re = serializeState(loadState(role));
		expect(re).toEqual([
			{ action: 'read', on: 'crm.Deal' },
			{ action: 'move_stage', on: 'crm.Deal', scope: ['$mine'] },
			{ action: 'win', on: 'crm.Deal' }
		]);
	});

	// B-87 — route-gated named actions (e.g. the IAM operator actions) are
	// stored lines the editor must preserve, now authorable in the UI.
	it('round-trips route-gated named actions through loadState', () => {
		const role = {
			name: 'hr_manager',
			permissions: [
				{ action: 'provision_credentials', on: 'iam.Account' },
				{ action: 'mfa_disable', on: 'iam.Account' }
			]
		};
		const re = serializeState(loadState(role));
		expect(re).toEqual([
			{ action: 'mfa_disable', on: 'iam.Account' },
			{ action: 'provision_credentials', on: 'iam.Account' }
		]);
	});
});

// ── scopeOptionsFor ──────────────────────────────────────────────────────────

describe('scopeOptionsFor', () => {
	it('returns an empty array when the doctype declares no scopes', () => {
		const tree = buildTree(new Map([['a.Leaf', def('a', 'Leaf', { aggregate_root: true })]]));
		expect(scopeOptionsFor(tree[0].roots[0].def)).toEqual([]);
	});

	it('lists each declared alias as `$<alias> — description`', () => {
		const tree = buildTree(productionDefs);
		const project = tree
			.find((d) => d.domain === 'production')!
			.roots.find((r) => r.doctype === 'Project')!;
		const opts = scopeOptionsFor(project.def);
		const values = opts.map((o) => o.value);
		expect(values).toEqual(['$active', '$mine']); // sorted alphabetically
		expect(opts.find((o) => o.value === '$mine')?.label).toContain('actioner');
	});

	it('uses the bare alias as label when no description is set', () => {
		const tree = buildTree(productionDefs);
		const task = tree
			.find((d) => d.domain === 'production')!
			.roots.find((r) => r.doctype === 'Project')!.children[0];
		const opts = scopeOptionsFor(task.def);
		expect(opts.map((o) => o.value)).toEqual(['$mine']);
		expect(opts[0].label).toBe('$mine');
	});
});

// ── actionsFor ──────────────────────────────────────────────────────────────

describe('actionsFor', () => {
	it('returns the four canonical actions when the doctype declares none', () => {
		const tree = buildTree(new Map([['a.Leaf', def('a', 'Leaf', { aggregate_root: true })]]));
		expect(actionsFor(tree[0].roots[0].def)).toEqual([...CORE_ACTIONS]);
	});

	it('appends custom actions in alphabetical order after the CRUD four', () => {
		const tree = buildTree(crmDealDefs);
		const deal = tree.find((d) => d.domain === 'crm')!.roots[0];
		expect(actionsFor(deal.def)).toEqual([
			'read',
			'create',
			'update',
			'delete',
			'lose',
			'move_stage',
			'win'
		]);
	});

	it('falls back to the canonical four when `actions` is absent', () => {
		const tree = buildTree(productionDefs);
		const project = tree.find((d) => d.domain === 'production')!.roots[0];
		expect(actionsFor(project.def)).toEqual([...CORE_ACTIONS]);
	});

	it('appends the route-gated operator actions for iam.Account', () => {
		const tree = buildTree(
			new Map([['iam.Account', def('iam', 'Account', { aggregate_root: true })]])
		);
		expect(actionsFor(tree[0].roots[0].def)).toEqual([
			'read',
			'create',
			'update',
			'delete',
			'mfa_disable',
			'provision_credentials'
		]);
	});

	it('merges declared and route-gated actions without duplicates', () => {
		const tree = buildTree(
			new Map([['iam.Account', def('iam', 'Account', { actions: { mfa_disable: {} } })]])
		);
		expect(actionsFor(tree[0].roots[0].def)).toEqual([
			'read',
			'create',
			'update',
			'delete',
			'mfa_disable',
			'provision_credentials'
		]);
	});

	it('leaves doctypes without route-gated actions untouched', () => {
		const tree = buildTree(new Map([['iam.Roles', def('iam', 'Roles', { aggregate_root: true })]]));
		expect(actionsFor(tree[0].roots[0].def)).toEqual([...CORE_ACTIONS]);
	});
});

// ── actionDescription ────────────────────────────────────────────────────────

describe('actionDescription', () => {
	it('returns the route-gated description for an IAM operator action', () => {
		const account = asDoctypeDef(def('iam', 'Account'));
		expect(actionDescription(account, 'provision_credentials')).toContain('temporary passwords');
		expect(actionDescription(account, 'mfa_disable')).toBeTruthy();
	});

	it('returns a declared action description when present', () => {
		const deal = asDoctypeDef(
			def('crm', 'Deal', { actions: { move_stage: { description: 'Move the deal stage' } } })
		);
		expect(actionDescription(deal, 'move_stage')).toBe('Move the deal stage');
	});

	it('returns undefined for canonical CRUD and unknown actions', () => {
		const account = asDoctypeDef(def('iam', 'Account'));
		expect(actionDescription(account, 'read')).toBeUndefined();
		expect(actionDescription(account, 'nonexistent')).toBeUndefined();
	});
});

// ── roleOptions ──────────────────────────────────────────────────────────────

describe('roleOptions', () => {
	it('builds options sorted by label', () => {
		const opts = roleOptions([
			{ data: { name: 'viewer', description: 'ro' } },
			{ data: { name: 'admin', description: 'all' } },
			{ data: { description: 'no name' } } // dropped
		]);
		expect(opts).toEqual([
			{ value: 'admin', label: 'Admin' },
			{ value: 'viewer', label: 'Viewer' }
		]);
	});
});

// ── deriveExpandedKeys ──────────────────────────────────────────────────────

describe('deriveExpandedKeys', () => {
	const tree = buildTree(productionDefs);

	it('returns an empty set when the role has no permissions', () => {
		expect(deriveExpandedKeys(tree, {})).toEqual(new Set());
	});

	it('expands the touched root doctype only', () => {
		const state = loadState({
			name: 'r',
			permissions: [{ action: 'read', on: 'production.Project' }]
		});
		expect(deriveExpandedKeys(tree, state)).toEqual(new Set(['production.Project']));
	});

	it('expands ancestor chain when a leaf doctype is touched', () => {
		const state = loadState({
			name: 'r',
			permissions: [{ action: 'read', on: 'production.Task' }]
		});
		// `production.Task` is a child of `production.Project` in the tree, but
		// the wire-format `on` is `{domain}.{LeafDoctype}` — not the full
		// tree path. The walk matches by `node.qualified`, which also yields
		// `production.Task` for the Task node under Project.
		expect(deriveExpandedKeys(tree, state)).toEqual(
			new Set(['production.Project', 'production.Task'])
		);
	});

	it('expands a single ancestor when multiple descendants are touched', () => {
		const state = loadState({
			name: 'r',
			permissions: [
				{ action: 'read', on: 'production.Team' },
				{ action: 'read', on: 'production.TeamMember' }
			]
		});
		const expanded = deriveExpandedKeys(tree, state);
		expect(expanded.has('production.Team')).toBe(true);
		expect(expanded.has('production.TeamMember')).toBe(true);
	});

	it('does not expand unrelated roots', () => {
		const state = loadState({
			name: 'r',
			permissions: [{ action: 'read', on: 'production.Team' }]
		});
		const expanded = deriveExpandedKeys(tree, state);
		expect(expanded.has('production.Project')).toBe(false);
		expect(expanded.has('production.Task')).toBe(false);
	});

	it('regression: production_editor touches both Project and Task with mixed scopes', () => {
		const state = loadState({
			name: 'production_editor',
			permissions: [
				{ action: 'read', on: 'production.Project' },
				{ action: 'update', on: 'production.Project', scope: ['$mine'] },
				{ action: 'read', on: 'production.Task', scope: ['$mine'] },
				{ action: 'update', on: 'production.Task', scope: ['$mine'] }
			]
		});
		expect(state['production.Project'].read).toEqual([ALL_SCOPE]);
		expect(state['production.Project'].update).toEqual(['$mine']);
		expect(state['production.Task'].read).toEqual(['$mine']);
		expect(state['production.Task'].update).toEqual(['$mine']);
		// Both Project (root) and Task (child) are expanded so the user sees
		// every touched row without manual expansion.
		const expanded = deriveExpandedKeys(tree, state);
		expect(expanded.has('production.Project')).toBe(true);
		expect(expanded.has('production.Task')).toBe(true);
		// Sibling subtree is untouched.
		expect(expanded.has('production.Team')).toBe(false);
	});
});

// ── filterTree ───────────────────────────────────────────────────────────────

describe('filterTree', () => {
	const tree = buildTree(productionDefs);

	function collectDoctypes(roots: DoctypeNode[], acc: string[] = []): string[] {
		for (const root of roots) {
			acc.push(root.doctype);
			collectDoctypes(root.children, acc);
		}
		return acc;
	}

	it('returns the input tree unchanged on empty query', () => {
		expect(filterTree(tree, '')).toBe(tree);
	});

	it('returns the input tree unchanged on whitespace-only query', () => {
		expect(filterTree(tree, '   ')).toBe(tree);
	});

	it('matches a root doctype and keeps its full subtree', () => {
		const filtered = filterTree(tree, 'Project');
		const domains = filtered.map((d) => d.domain);
		expect(domains).toContain('production');
		const production = filtered.find((d) => d.domain === 'production')!;
		expect(production.roots.map((r) => r.doctype)).toEqual(['Project']);
		// Task (descendant of Project) must remain even though it doesn't match.
		expect(production.roots[0].children.map((c) => c.doctype)).toEqual(['Task']);
	});

	it('matches a leaf doctype and keeps its ancestor chain', () => {
		const filtered = filterTree(tree, 'Task');
		const production = filtered.find((d) => d.domain === 'production')!;
		// Project must remain as scaffolding so Task is reachable in-tree.
		expect(production.roots.map((r) => r.doctype)).toEqual(['Project']);
		expect(production.roots[0].children.map((c) => c.doctype)).toEqual(['Task']);
		// Team (sibling subtree with no Task descendant) is pruned.
		expect(production.roots.map((r) => r.doctype)).not.toContain('Team');
	});

	it("matches by domain name and shows all of that domain's doctypes", () => {
		const filtered = filterTree(tree, 'production');
		const production = filtered.find((d) => d.domain === 'production')!;
		expect(collectDoctypes(production.roots).sort()).toEqual(
			['Project', 'Task', 'Team', 'TeamMember'].sort()
		);
		// Other domains are pruned entirely.
		expect(filtered.map((d) => d.domain)).toEqual(['production']);
	});

	it('matches case-insensitively', () => {
		const filtered = filterTree(tree, 'task');
		const production = filtered.find((d) => d.domain === 'production')!;
		expect(production.roots[0].children[0].doctype).toBe('Task');
	});

	it('prunes everything when nothing matches', () => {
		const filtered = filterTree(tree, 'zzzz-not-a-thing');
		expect(filtered).toEqual([]);
	});

	it('matches the qualified path substring', () => {
		const filtered = filterTree(tree, 'TeamMember');
		const production = filtered.find((d) => d.domain === 'production')!;
		// Team is kept as scaffolding; TeamMember is the match target.
		expect(production.roots.map((r) => r.doctype)).toEqual(['Team']);
		expect(production.roots[0].children.map((c) => c.doctype)).toEqual(['TeamMember']);
		// Project subtree is entirely pruned (no TeamMember descendant).
		expect(production.roots.map((r) => r.doctype)).not.toContain('Project');
	});

	it('exposes a DomainTree with the matched domain even when no doctype matches', () => {
		// `production` matches the domain name but not any doctype name;
		// the domain should still appear with its full root set.
		const filtered = filterTree(buildTree(productionDefs), 'production');
		expect(filtered.length).toBeGreaterThan(0);
		const domain: DomainTree = filtered.find((d) => d.domain === 'production')!;
		expect(domain.roots.length).toBeGreaterThan(0);
	});
});
