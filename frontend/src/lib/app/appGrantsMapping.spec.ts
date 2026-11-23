// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import * as m from '$lib/paraglide/messages';
import {
	levelToActions,
	actionsToLevel,
	summarizeGrants,
	resolveEffectiveLevel,
	effectiveRequireds,
	levelActionNames,
	coreActionVerb,
	hasExplicitGrant,
	clampChildLevel,
	clearChildrenExceedingParent,
	materialiseInherited,
	fallbackPlural,
	anySensitiveGranted,
	canonicalActions,
	isCoreActionName,
	type PlainLevel
} from './appGrantsMapping.js';
import type { AppGrant, AppGrantAction, DoctypeCatalogueEntry } from './appTypes.js';

// A minimal catalogue used across the spec. Indices match the qualified
// targets so tests can reference them without re-typing.
function makeCatalogue(entries: Partial<DoctypeCatalogueEntry>[]): DoctypeCatalogueEntry[] {
	return entries.map((e) => ({
		target: e.target!,
		label: e.label ?? e.target!.split('.').pop()!,
		description: e.description ?? '',
		domain: e.domain ?? e.target!.split('.')[0],
		pluralLabel: e.pluralLabel ?? fallbackPlural(e.target!),
		namedActions: e.namedActions,
		sensitive: e.sensitive,
		parentTarget: e.parentTarget
	}));
}

const CATALOGUE = makeCatalogue([
	{ target: 'crm.Company', pluralLabel: 'companies' },
	{
		target: 'crm.CompanyMembership',
		parentTarget: 'crm.Company',
		pluralLabel: 'company memberships'
	},
	{ target: 'crm.CompanyNote', parentTarget: 'crm.Company', pluralLabel: 'company notes' },
	{ target: 'crm.Contact', sensitive: true, pluralLabel: 'contacts' },
	{ target: 'crm.Activity', pluralLabel: 'activities' },
	{
		target: 'crm.Company',
		// Re-declare to attach a named action on Company for the verb tests.
		namedActions: [
			{ name: 'merge', label: 'Merge' },
			{ name: 'convert', label: 'Convert' }
		]
	}
]);
// The catalogue duplicate above is intentional in shape only; for the test
// helpers, the first declaration wins the map. To attach named actions on
// Company in a single clean catalogue for the verb tests, build a dedicated
// one below.

const CATALOGUE_WITH_NAMED = makeCatalogue([
	{
		target: 'crm.Company',
		pluralLabel: 'companies',
		namedActions: [
			{ name: 'merge', label: 'Merge' },
			{ name: 'convert', label: 'Convert' }
		]
	},
	{ target: 'crm.Contact', sensitive: true, pluralLabel: 'contacts' },
	{ target: 'crm.Activity', pluralLabel: 'activities' }
]);

describe('appGrantsMapping — levelToActions', () => {
	it('produces no actions for the "none" level', () => {
		expect(levelToActions('none')).toEqual([]);
		expect(levelToActions('none', { read: true })).toEqual([]);
	});

	it('produces read-only for the "read" level', () => {
		expect(levelToActions('read')).toEqual([{ name: 'read', required: false }]);
	});

	it('produces read + create + update for the "write" level (canonical form)', () => {
		// The picker writes the backend's canonical vocabulary directly: the
		// `write` alias is never persisted (`src/rbac/grant.cr` expands it to
		// the same pair at parse time).
		expect(levelToActions('write')).toEqual([
			{ name: 'read', required: false },
			{ name: 'create', required: false },
			{ name: 'update', required: false }
		]);
	});

	it('produces read + create + update + delete for the "full" level (canonical form)', () => {
		expect(levelToActions('full')).toEqual([
			{ name: 'read', required: false },
			{ name: 'create', required: false },
			{ name: 'update', required: false },
			{ name: 'delete', required: false }
		]);
	});

	it('honours the per-action required flags', () => {
		expect(levelToActions('full', { read: true, write: false, delete: true })).toEqual([
			{ name: 'read', required: true },
			{ name: 'create', required: false },
			{ name: 'update', required: false },
			{ name: 'delete', required: true }
		]);
		// The `write` display flag rides on both canonical declarations.
		expect(levelToActions('write', { write: true })).toEqual([
			{ name: 'read', required: false },
			{ name: 'create', required: true },
			{ name: 'update', required: true }
		]);
	});

	it('defaults unknown required keys to false', () => {
		expect(levelToActions('read', { unrelated: true })).toEqual([
			{ name: 'read', required: false }
		]);
	});
});

describe('appGrantsMapping — actionsToLevel', () => {
	const cases: {
		level: Exclude<PlainLevel, 'none'>;
		actions: ReturnType<typeof levelToActions>;
	}[] = [
		{ level: 'read', actions: levelToActions('read') },
		{ level: 'write', actions: levelToActions('write') },
		{ level: 'full', actions: levelToActions('full') }
	];
	for (const { level, actions } of cases) {
		it(`recovers ${level} from its actions`, () => {
			expect(actionsToLevel(actions)).toBe(level);
		});
	}

	it('classifies canonical grants authored outside the editor', () => {
		// The CRM-app shape: all four canonical declarations, all required.
		const canonicalFull: AppGrantAction[] = [
			{ name: 'read', required: true },
			{ name: 'create', required: true },
			{ name: 'update', required: true },
			{ name: 'delete', required: true }
		];
		expect(actionsToLevel(canonicalFull)).toBe('full');
		expect(
			actionsToLevel([
				{ name: 'read', required: true },
				{ name: 'create', required: true },
				{ name: 'update', required: true }
			])
		).toBe('write');
		expect(actionsToLevel([{ name: 'read', required: true }])).toBe('read');
	});

	it('degrades a partial canonical set to the highest level it fully covers', () => {
		// Never over-claim: the picker shows the closest level below the
		// grant; the consent summary still lists every action.
		expect(
			actionsToLevel([
				{ name: 'read', required: true },
				{ name: 'delete', required: true }
			])
		).toBe('read');
		expect(
			actionsToLevel([
				{ name: 'read', required: false },
				{ name: 'create', required: false }
			])
		).toBe('read');
	});

	it('returns "none" for a create/update pair without read', () => {
		// The picker's levels always include read; a read-less write pair has
		// no representable level. The entry survives untouched — only the
		// summary discloses it.
		expect(
			actionsToLevel([
				{ name: 'create', required: true },
				{ name: 'update', required: true }
			])
		).toBe('none');
	});

	it('returns "none" for an empty actions array', () => {
		expect(actionsToLevel([])).toBe('none');
	});

	it('returns "none" when only named actions are present', () => {
		expect(actionsToLevel([{ name: 'export', required: false }])).toBe('none');
	});

	it('ignores named actions layered on a level', () => {
		expect(
			actionsToLevel([
				{ name: 'read', required: true },
				{ name: 'write', required: false },
				{ name: 'export', required: false }
			])
		).toBe('write');
		expect(
			actionsToLevel([
				{ name: 'read', required: false },
				{ name: 'write', required: false },
				{ name: 'delete', required: true },
				{ name: 'export', required: false }
			])
		).toBe('full');
	});

	it('honours the required flags but classifies by action names only', () => {
		expect(
			actionsToLevel([
				{ name: 'read', required: true },
				{ name: 'write', required: true }
			])
		).toBe('write');
	});

	it('is order-independent (sorts action names)', () => {
		expect(
			actionsToLevel([
				{ name: 'write', required: false },
				{ name: 'read', required: false }
			])
		).toBe('write');
	});
});

describe('appGrantsMapping — clampChildLevel', () => {
	it('returns the desired level when it does not exceed the parent', () => {
		expect(clampChildLevel('read', 'write')).toBe('read');
		expect(clampChildLevel('write', 'write')).toBe('write');
		expect(clampChildLevel('full', 'full')).toBe('full');
		expect(clampChildLevel('none', 'read')).toBe('none');
	});

	it('clamps the desired level down to the parent when it exceeds it', () => {
		expect(clampChildLevel('write', 'read')).toBe('read');
		expect(clampChildLevel('full', 'read')).toBe('read');
		expect(clampChildLevel('full', 'write')).toBe('write');
	});

	it('clamps to none when the parent is none', () => {
		expect(clampChildLevel('read', 'none')).toBe('none');
		expect(clampChildLevel('full', 'none')).toBe('none');
	});
});

describe('appGrantsMapping — resolveEffectiveLevel / hasExplicitGrant', () => {
	it('returns the doctype own level when it has an explicit grant', () => {
		const grants: AppGrant[] = [{ target: 'crm.Contact', actions: levelToActions('write') }];
		expect(resolveEffectiveLevel(grants, 'crm.Contact', CATALOGUE)).toBe('write');
		expect(hasExplicitGrant(grants, 'crm.Contact')).toBe(true);
	});

	it('returns none when neither the doctype nor its parent has a grant', () => {
		expect(resolveEffectiveLevel([], 'crm.CompanyMembership', CATALOGUE)).toBe('none');
		expect(hasExplicitGrant([], 'crm.CompanyMembership')).toBe(false);
	});

	it('inherits the parent level when the child has no explicit grant', () => {
		const grants: AppGrant[] = [{ target: 'crm.Company', actions: levelToActions('write') }];
		expect(resolveEffectiveLevel(grants, 'crm.CompanyMembership', CATALOGUE)).toBe('write');
		expect(hasExplicitGrant(grants, 'crm.CompanyMembership')).toBe(false);
	});

	it('does not walk past a child that has its own grant to the grandparent', () => {
		// CompanyMembership has its own read; even though Company has write,
		// the child reads as read (its own explicit level wins).
		const grants: AppGrant[] = [
			{ target: 'crm.Company', actions: levelToActions('write') },
			{ target: 'crm.CompanyMembership', actions: levelToActions('read') }
		];
		expect(resolveEffectiveLevel(grants, 'crm.CompanyMembership', CATALOGUE)).toBe('read');
		expect(hasExplicitGrant(grants, 'crm.CompanyMembership')).toBe(true);
	});

	it('returns none for a target not in the catalogue', () => {
		expect(resolveEffectiveLevel([], 'crm.NoSuch', CATALOGUE)).toBe('none');
	});

	it('guards against parent cycles', () => {
		// Craft a catalogue with a 2-cycle. The walk must stop, not loop
		// forever, and return none when neither side has a grant.
		const cyclic = makeCatalogue([
			{ target: 'a.X', parentTarget: 'a.Y' },
			{ target: 'a.Y', parentTarget: 'a.X' }
		]);
		expect(resolveEffectiveLevel([], 'a.X', cyclic)).toBe('none');
	});

	it('walks past a child that has only named actions to inherit the parent core level', () => {
		// CompanyMembership has only a named action (e.g. merge) and no core
		// read/write/delete. The picker displays named-action pills on a
		// base level — the base level must come from the parent, not be none.
		const grants: AppGrant[] = [
			{ target: 'crm.Company', actions: levelToActions('write') },
			{ target: 'crm.CompanyMembership', actions: [{ name: 'merge', required: false }] }
		];
		expect(resolveEffectiveLevel(grants, 'crm.CompanyMembership', CATALOGUE)).toBe('write');
		// The child still counts as having an explicit grant (its own entry),
		// so the editor labels it "overridden" rather than "inherited".
		expect(hasExplicitGrant(grants, 'crm.CompanyMembership')).toBe(true);
	});
});

describe('appGrantsMapping — clearChildrenExceedingParent', () => {
	it('keeps children at or below the parent level', () => {
		const grants: AppGrant[] = [
			{ target: 'crm.Company', actions: levelToActions('write') },
			{ target: 'crm.CompanyMembership', actions: levelToActions('read') }
		];
		const next = clearChildrenExceedingParent(grants, 'crm.Company', CATALOGUE);
		expect(next).toEqual(grants);
	});

	it('removes a child whose explicit level exceeds the parent after a drop', () => {
		const grants: AppGrant[] = [
			{ target: 'crm.Company', actions: levelToActions('read') },
			// Parent dropped to read; this child needs write — clear it.
			{ target: 'crm.CompanyMembership', actions: levelToActions('write') }
		];
		const next = clearChildrenExceedingParent(grants, 'crm.Company', CATALOGUE);
		expect(next.find((g) => g.target === 'crm.CompanyMembership')).toBeUndefined();
		expect(next.find((g) => g.target === 'crm.Company')).toBeDefined();
	});

	it('does not mutate the input array', () => {
		const grants: AppGrant[] = [
			{ target: 'crm.Company', actions: levelToActions('read') },
			{ target: 'crm.CompanyMembership', actions: levelToActions('write') }
		];
		const snapshot = JSON.stringify(grants);
		clearChildrenExceedingParent(grants, 'crm.Company', CATALOGUE);
		expect(JSON.stringify(grants)).toBe(snapshot);
	});
});

describe('appGrantsMapping — materialiseInherited', () => {
	it('writes an explicit grant for an inherited child when the parent is granted', () => {
		const grants: AppGrant[] = [{ target: 'crm.Company', actions: levelToActions('write') }];
		const next = materialiseInherited(grants, CATALOGUE);
		// CompanyMembership and CompanyNote both inherit write from Company.
		const cm = next.find((g) => g.target === 'crm.CompanyMembership');
		const cn = next.find((g) => g.target === 'crm.CompanyNote');
		expect(cm).toBeDefined();
		expect(cn).toBeDefined();
		expect(actionsToLevel(cm!.actions)).toBe('write');
		expect(actionsToLevel(cn!.actions)).toBe('write');
	});

	it('does not overwrite a child that already has its own explicit grant', () => {
		const grants: AppGrant[] = [
			{ target: 'crm.Company', actions: levelToActions('write') },
			{ target: 'crm.CompanyMembership', actions: levelToActions('read') }
		];
		const next = materialiseInherited(grants, CATALOGUE);
		const cm = next.find((g) => g.target === 'crm.CompanyMembership');
		expect(actionsToLevel(cm!.actions)).toBe('read');
		// The other child still inherits.
		expect(actionsToLevel(next.find((g) => g.target === 'crm.CompanyNote')!.actions)).toBe('write');
	});

	it('adds the parent core level under a child that only has named actions', () => {
		// Company is at write. CompanyMembership has only a named action
		// (e.g. merge) but no core level — the materialisation must add the
		// inherited write under it so the named action has a base level.
		const grants: AppGrant[] = [
			{ target: 'crm.Company', actions: levelToActions('write') },
			{
				target: 'crm.CompanyMembership',
				actions: [{ name: 'merge', required: false }]
			}
		];
		const next = materialiseInherited(grants, CATALOGUE);
		const cm = next.find((g) => g.target === 'crm.CompanyMembership');
		expect(actionsToLevel(cm!.actions)).toBe('write');
		expect(cm!.actions.some((a) => a.name === 'merge')).toBe(true);
	});

	it('materialises an inherited child with the parent required flags', () => {
		// Company: read required. The membership child inherits read — the
		// materialised entry must carry the same required flag, so what the
		// picker displays is what persists.
		const grants: AppGrant[] = [
			{ target: 'crm.Company', actions: levelToActions('read', { read: true }) }
		];
		const next = materialiseInherited(grants, CATALOGUE);
		const cm = next.find((g) => g.target === 'crm.CompanyMembership');
		expect(cm!.actions).toEqual([{ name: 'read', required: true }]);
	});

	it('layers the inherited core level with the parent flags under a named-only child', () => {
		const grants: AppGrant[] = [
			{ target: 'crm.Company', actions: levelToActions('write', { write: true }) },
			{ target: 'crm.CompanyMembership', actions: [{ name: 'merge', required: false }] }
		];
		const next = materialiseInherited(grants, CATALOGUE);
		const cm = next.find((g) => g.target === 'crm.CompanyMembership');
		expect(actionsToLevel(cm!.actions)).toBe('write');
		expect(cm!.actions.find((a) => a.name === 'create')).toEqual({
			name: 'create',
			required: true
		});
		expect(cm!.actions.find((a) => a.name === 'update')).toEqual({
			name: 'update',
			required: true
		});
		expect(cm!.actions.find((a) => a.name === 'read')).toEqual({ name: 'read', required: false });
		// The child's own named action keeps its own flag.
		expect(cm!.actions.find((a) => a.name === 'merge')).toEqual({ name: 'merge', required: false });
	});

	it('keeps one declaration per action when a child already carries the canonical pair', () => {
		// Degenerate external shape: create/update without read. The walk
		// resolves the parent's level and layers it under; the canonicalising
		// merge must not emit duplicated create/update declarations.
		const grants: AppGrant[] = [
			{ target: 'crm.Company', actions: levelToActions('write', { write: true }) },
			{
				target: 'crm.CompanyMembership',
				actions: [
					{ name: 'create', required: false },
					{ name: 'update', required: false }
				]
			}
		];
		const next = materialiseInherited(grants, CATALOGUE);
		const cm = next.find((g) => g.target === 'crm.CompanyMembership')!;
		expect(cm.actions.filter((a) => a.name === 'create')).toHaveLength(1);
		expect(cm.actions.filter((a) => a.name === 'update')).toHaveLength(1);
		expect(actionsToLevel(cm.actions)).toBe('write');
	});

	it('writes nothing when the parent is at none', () => {
		const grants: AppGrant[] = [];
		const next = materialiseInherited(grants, CATALOGUE);
		expect(next).toEqual([]);
	});

	it('does not mutate the input array', () => {
		const grants: AppGrant[] = [{ target: 'crm.Company', actions: levelToActions('write') }];
		const snapshot = JSON.stringify(grants);
		materialiseInherited(grants, CATALOGUE);
		expect(JSON.stringify(grants)).toBe(snapshot);
	});
});

describe('appGrantsMapping — effectiveRequireds', () => {
	it('returns the explicit entry flags for its own target', () => {
		const grants: AppGrant[] = [
			{ target: 'crm.Contact', actions: levelToActions('write', { read: true }) }
		];
		expect(effectiveRequireds(grants, 'crm.Contact', CATALOGUE)).toEqual({
			read: true,
			write: false
		});
	});

	it('walks to the nearest ancestor grant for an inherited child', () => {
		const grants: AppGrant[] = [
			{ target: 'crm.Company', actions: levelToActions('read', { read: true }) }
		];
		expect(effectiveRequireds(grants, 'crm.CompanyMembership', CATALOGUE)).toEqual({
			read: true
		});
	});

	it('skips a named-only entry and keeps walking to the ancestor', () => {
		const grants: AppGrant[] = [
			{ target: 'crm.Company', actions: levelToActions('read', { read: true }) },
			{ target: 'crm.CompanyMembership', actions: [{ name: 'merge', required: true }] }
		];
		// The membership entry has no core level of its own, so the flags come
		// from the Company grant above it.
		expect(effectiveRequireds(grants, 'crm.CompanyMembership', CATALOGUE)).toEqual({
			read: true
		});
	});

	it('returns an empty map when no grant backs the doctype', () => {
		expect(effectiveRequireds([], 'crm.Contact', CATALOGUE)).toEqual({});
	});

	it('collapses the canonical create/update pair into the single write flag', () => {
		// All-required canonical entry (the CRM-app shape): every display flag
		// reads as required.
		const grants: AppGrant[] = [
			{
				target: 'crm.Contact',
				actions: [
					{ name: 'read', required: true },
					{ name: 'create', required: true },
					{ name: 'update', required: true },
					{ name: 'delete', required: true }
				]
			}
		];
		expect(effectiveRequireds(grants, 'crm.Contact', CATALOGUE)).toEqual({
			read: true,
			write: true,
			delete: true
		});
	});

	it('shows the write flag as optional unless both declarations are required', () => {
		// Divergent external flags: the picker shows one pill for the pair,
		// required only when both are required. Flipping it sets both.
		const grants: AppGrant[] = [
			{
				target: 'crm.Contact',
				actions: [
					{ name: 'read', required: true },
					{ name: 'create', required: true },
					{ name: 'update', required: false },
					{ name: 'delete', required: true }
				]
			}
		];
		expect(effectiveRequireds(grants, 'crm.Contact', CATALOGUE)).toEqual({
			read: true,
			write: false,
			delete: true
		});
	});
});

describe('appGrantsMapping — levelActionNames / coreActionVerb', () => {
	it('lists the display action names a level grants, in display order', () => {
		// `write` is the display alias for the canonical create/update pair —
		// one pill, one flag.
		expect(levelActionNames('read')).toEqual(['read']);
		expect(levelActionNames('write')).toEqual(['read', 'write']);
		expect(levelActionNames('full')).toEqual(['read', 'write', 'delete']);
		expect(levelActionNames('none')).toEqual([]);
	});

	it('maps core action names to the consent verbs', () => {
		expect(coreActionVerb('read')).toBe(m.apps_grants_verb_read());
		expect(coreActionVerb('write')).toBe(m.apps_grants_verb_write());
		expect(coreActionVerb('create')).toBe(m.apps_grants_verb_write());
		expect(coreActionVerb('update')).toBe(m.apps_grants_verb_write());
		expect(coreActionVerb('delete')).toBe(m.apps_grants_verb_delete());
	});
});

describe('appGrantsMapping — canonicalActions / isCoreActionName', () => {
	it('expands the write alias into the canonical pair', () => {
		expect(canonicalActions([{ name: 'write', required: true }])).toEqual([
			{ name: 'create', required: true },
			{ name: 'update', required: true }
		]);
	});

	it('keeps the first required flag when a name is declared twice', () => {
		// Mirrors Grant.from_json: the first declaration wins, a later
		// conflicting one is dropped.
		expect(
			canonicalActions([
				{ name: 'write', required: true },
				{ name: 'create', required: false }
			])
		).toEqual([
			{ name: 'create', required: true },
			{ name: 'update', required: true }
		]);
	});

	it('passes canonical and named names through unchanged, in order', () => {
		expect(
			canonicalActions([
				{ name: 'read', required: true },
				{ name: 'create', required: true },
				{ name: 'update', required: true },
				{ name: 'delete', required: true },
				{ name: 'export', required: false }
			])
		).toEqual([
			{ name: 'read', required: true },
			{ name: 'create', required: true },
			{ name: 'update', required: true },
			{ name: 'delete', required: true },
			{ name: 'export', required: false }
		]);
	});

	it('fails safe on a non-array input', () => {
		expect(canonicalActions(null as unknown as AppGrantAction[])).toEqual([]);
		expect(canonicalActions({} as unknown as AppGrantAction[])).toEqual([]);
	});

	it('treats the canonical four and the write alias as core', () => {
		expect(isCoreActionName('read')).toBe(true);
		expect(isCoreActionName('create')).toBe(true);
		expect(isCoreActionName('update')).toBe(true);
		expect(isCoreActionName('delete')).toBe(true);
		expect(isCoreActionName('write')).toBe(true);
		expect(isCoreActionName('export')).toBe(false);
	});
});

describe('appGrantsMapping — summarizeGrants (grouped)', () => {
	it('returns no groups for an empty grants array', () => {
		expect(summarizeGrants([], CATALOGUE)).toEqual([]);
	});

	it('fails safe on a non-array grants value', () => {
		// `app.App.grants` is array-typed on the doctype, but an empty array
		// can round-trip from the Lua lifecycle hook as a non-iterable JSON
		// shape (e.g. `{}`). The function must fail safe instead of throwing
		// "grants is not iterable" when the input is not an array.
		expect(summarizeGrants(null as unknown as AppGrant[], CATALOGUE)).toEqual([]);
		expect(summarizeGrants({} as unknown as AppGrant[], CATALOGUE)).toEqual([]);
	});

	it('groups multiple targets sharing a verb into one group with all nouns', () => {
		const grants: AppGrant[] = [
			{ target: 'crm.Company', actions: levelToActions('read') },
			{ target: 'crm.Contact', actions: levelToActions('read') },
			{ target: 'crm.Activity', actions: levelToActions('read') }
		];
		const groups = summarizeGrants(grants, CATALOGUE);
		expect(groups).toHaveLength(1);
		expect(groups[0].verb).toBe(m.apps_grants_verb_read());
		expect(groups[0].targets).toEqual(['companies', 'contacts', 'activities']);
		expect(groups[0].optional).toBe(true);
	});

	it('produces separate groups for read and write (Create and edit)', () => {
		// crm.Company gets read; crm.Contact gets write (read + write). Both
		// therefore appear in the Read group; only crm.Contact appears in
		// Create and edit.
		const grants: AppGrant[] = [
			{ target: 'crm.Company', actions: levelToActions('read') },
			{ target: 'crm.Contact', actions: levelToActions('write') }
		];
		const groups = summarizeGrants(grants, CATALOGUE);
		expect(groups.map((g) => g.verb)).toEqual([
			m.apps_grants_verb_read(),
			m.apps_grants_verb_write()
		]);
		expect(groups[0].targets).toEqual(['companies', 'contacts']);
		expect(groups[1].targets).toEqual(['contacts']);
	});

	it('marks a group as not optional when any action in it is required', () => {
		const grants: AppGrant[] = [
			{
				target: 'crm.Company',
				actions: [
					{ name: 'read', required: true },
					{ name: 'write', required: false }
				]
			}
		];
		const groups = summarizeGrants(grants, CATALOGUE);
		const readGroup = groups.find((g) => g.verb === m.apps_grants_verb_read());
		expect(readGroup?.optional).toBe(false);
	});

	it('uses the plural_label from the catalogue instead of the naive pluraliser', () => {
		const grants: AppGrant[] = [
			{ target: 'crm.CompanyMembership', actions: levelToActions('read') }
		];
		const groups = summarizeGrants(grants, CATALOGUE);
		expect(groups[0].targets).toEqual(['company memberships']);
	});

	it('falls back to the naive pluraliser when the catalogue has no pluralLabel', () => {
		const minimal = makeCatalogue([{ target: 'crm.Deal' }]);
		const grants: AppGrant[] = [{ target: 'crm.Deal', actions: levelToActions('read') }];
		const groups = summarizeGrants(grants, minimal);
		expect(groups[0].targets).toEqual(['deals']);
	});

	it('renders named actions as their own group with the doctype-declared verb label', () => {
		const grants: AppGrant[] = [
			{
				target: 'crm.Company',
				actions: [
					{ name: 'merge', required: true },
					{ name: 'convert', required: true }
				]
			}
		];
		const groups = summarizeGrants(grants, CATALOGUE_WITH_NAMED);
		expect(groups.map((g) => g.verb).sort()).toEqual(['Convert', 'Merge']);
		// Named groups carry the noun inside their verb label, so the targets
		// list stays empty — the renderer must not append the noun again.
		expect(groups.every((g) => g.kind === 'named' && g.targets.length === 0)).toBe(true);
	});

	it('separates core verbs from named groups by kind', () => {
		// read is a core verb; export is a named action on crm.Contact.
		// They land in different groups with different kinds.
		const grants: AppGrant[] = [
			{
				target: 'crm.Contact',
				actions: [
					{ name: 'read', required: true },
					{ name: 'export', required: false }
				]
			}
		];
		const groups = summarizeGrants(grants, CATALOGUE);
		const readGroup = groups.find((g) => g.verb === m.apps_grants_verb_read());
		expect(readGroup?.kind).toBe('core');
		expect(readGroup?.targets).toEqual(['contacts']);
		const exportGroup = groups.find((g) => g.verb === 'export');
		expect(exportGroup?.kind).toBe('named');
		expect(exportGroup?.targets).toEqual([]);
	});

	it('produces a stable verb order: read, write, delete, then named', () => {
		// The named action `merge` is declared on crm.Company, so its verb label
		// is "Merge". Granting it on crm.Company (alongside read/write/delete)
		// exercises all four verbs on one target.
		const grants: AppGrant[] = [
			{
				target: 'crm.Company',
				actions: [
					{ name: 'delete', required: true },
					{ name: 'read', required: true },
					{ name: 'write', required: true },
					{ name: 'merge', required: true }
				]
			}
		];
		const groups = summarizeGrants(grants, CATALOGUE_WITH_NAMED);
		expect(groups.map((g) => g.verb)).toEqual([
			m.apps_grants_verb_read(),
			m.apps_grants_verb_write(),
			m.apps_grants_verb_delete(),
			'Merge'
		]);
	});

	it('groups canonical create/update grants under the Create and edit verb', () => {
		// Regression: the CRM-app shape. create/update are core actions in the
		// canonical vocabulary — they must fold into the "Create and edit"
		// group with a noun list, never render as bare named-action lines.
		const grants: AppGrant[] = [
			{
				target: 'crm.Company',
				actions: [
					{ name: 'read', required: true },
					{ name: 'create', required: true },
					{ name: 'update', required: true },
					{ name: 'delete', required: true }
				]
			}
		];
		const groups = summarizeGrants(grants, CATALOGUE);
		expect(groups).toHaveLength(3);
		expect(groups.map((g) => g.kind)).toEqual(['core', 'core', 'core']);
		expect(groups.map((g) => g.verb)).toEqual([
			m.apps_grants_verb_read(),
			m.apps_grants_verb_write(),
			m.apps_grants_verb_delete()
		]);
		expect(groups.every((g) => g.targets.includes('companies'))).toBe(true);
		expect(groups.every((g) => g.optional === false)).toBe(true);
	});

	it('folds the write alias and the canonical pair into one Create and edit group', () => {
		// A legacy alias entry and a canonical entry on different targets must
		// land in the same core bucket, not in separate named buckets.
		const grants: AppGrant[] = [
			{ target: 'crm.Company', actions: levelToActions('write') },
			{
				target: 'crm.Contact',
				actions: [
					{ name: 'read', required: false },
					{ name: 'create', required: false }
				]
			}
		];
		const groups = summarizeGrants(grants, CATALOGUE);
		const writeGroups = groups.filter((g) => g.verb === m.apps_grants_verb_write());
		expect(writeGroups).toHaveLength(1);
		expect(writeGroups[0].kind).toBe('core');
		expect(writeGroups[0].targets).toEqual(['companies', 'contacts']);
	});
});

describe('appGrantsMapping — anySensitiveGranted', () => {
	it('returns false when no sensitive doctype is granted', () => {
		const grants: AppGrant[] = [{ target: 'crm.Company', actions: levelToActions('read') }];
		expect(anySensitiveGranted(grants, CATALOGUE)).toBe(false);
	});

	it('returns true when a sensitive doctype is granted', () => {
		const grants: AppGrant[] = [{ target: 'crm.Contact', actions: levelToActions('read') }];
		expect(anySensitiveGranted(grants, CATALOGUE)).toBe(true);
	});

	it('fails safe on a non-array grants value', () => {
		expect(anySensitiveGranted(null as unknown as AppGrant[], CATALOGUE)).toBe(false);
	});
});

describe('appGrantsMapping — fallbackPlural', () => {
	it('lowercases and pluralises a qualified target', () => {
		expect(fallbackPlural('crm.Contact')).toBe('contacts');
		expect(fallbackPlural('crm.Activity')).toBe('activities');
	});

	it('appends es to words ending in s, x, or ch', () => {
		expect(fallbackPlural('crm.Box')).toBe('boxes');
		expect(fallbackPlural('crm.Class')).toBe('classes');
	});

	it('handles the y → ies rule for consonant-y endings', () => {
		expect(fallbackPlural('crm.Company')).toBe('companies');
	});

	it('leaves vowel-y endings plural with s', () => {
		expect(fallbackPlural('crm.Delay')).toBe('delays');
	});
});
