// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Unit tests for the RBAC matcher — the pure `canInManifest` helper and the
 * store-backed `can` / `canScope` gates (Node env, Vitest `server` project).
 *
 * The fixtures mirror the shape the backend's `build_permission_manifest`
 * emits, including the reserved `*.*.except.<action>` keys that carry the
 * per-action fold of the role's wildcard `except` carve-outs. The
 * wildcard-with-except case is the B-81 regression: a role like the seeded
 * `editor` holds `*.* → [create, update, delete, read]` plus carve-outs, and
 * every matcher here must grant through the `*.*` fallback for doctypes the
 * carve-outs do not subtract for that action (the B-85 regression — a single
 * union key hid the editor's Webhook create grant).
 */

import { describe, it, expect, afterEach } from 'vitest';
import {
	canInManifest,
	can,
	canScope,
	fieldVisible,
	fieldVisibleInTags,
	setPermissions,
	setScopes,
	setVisibleTags
} from './permissions.svelte';
import { setPreviewSession, clearPreviewSession } from './previewSession.svelte';

/**
 * The seeded-editor shape: four wildcard lines whose carve-outs differ per
 * action, the `$mine` re-grants on the definition surfaces and `core.Webhook`
 * (B-76 arbitration), and the per-action fold under the reserved keys.
 */
const EDITOR_MANIFEST = {
	'*.*': ['create', 'update', 'delete', 'read'],
	'core.Domain': ['update', 'delete'],
	'core.DocType': ['create', 'update', 'delete'],
	'core.Webhook': ['read', 'update', 'delete'],
	'*.*.except.create': [
		'core.DocType',
		'core.DocumentView',
		'core.DomainEditor',
		'core.SystemSettings',
		'iam.OIDCProvider'
	],
	'*.*.except.update': [
		'core.Domain',
		'core.DocType',
		'core.DocumentView',
		'core.DomainEditor',
		'core.SystemSettings',
		'iam.OIDCProvider',
		'core.Webhook'
	],
	'*.*.except.delete': [
		'core.Domain',
		'core.DocType',
		'core.DocumentView',
		'core.DomainEditor',
		'core.SystemSettings',
		'iam.OIDCProvider',
		'core.Webhook'
	],
	'*.*.except.read': ['core.SystemSettings', 'iam.OIDCProvider', 'core.Webhook']
};

/**
 * The seeded-viewer shape: one wildcard read line whose carve-outs subtract
 * the operator surfaces, plus the `$mine` re-grant on `core.Webhook`.
 */
const VIEWER_MANIFEST = {
	'*.*': ['read'],
	'core.Webhook': ['read'],
	'*.*.except.read': ['core.SystemSettings', 'iam.OIDCProvider', 'core.Webhook']
};

describe('canInManifest', () => {
	it('returns false without a manifest (fail-closed)', () => {
		expect(canInManifest(null, 'crm.Deal', 'read')).toBe(false);
		expect(canInManifest(undefined, 'crm.Deal', 'read')).toBe(false);
	});

	it('returns false for an empty manifest', () => {
		expect(canInManifest({}, 'crm.Deal', 'read')).toBe(false);
	});

	it('short-circuits to true on the admin wildcard *.* → ["*"]', () => {
		const manifest = { '*.*': ['*'] };
		expect(canInManifest(manifest, 'crm.Deal', 'read')).toBe(true);
		expect(canInManifest(manifest, 'core.SystemSettings', 'delete')).toBe(true);
		expect(canInManifest(manifest, 'anything.AtAll', 'promote')).toBe(true);
	});

	it('grants through an exact key', () => {
		const manifest = { 'crm.Deal': ['read', 'promote'] };
		expect(canInManifest(manifest, 'crm.Deal', 'read')).toBe(true);
		expect(canInManifest(manifest, 'crm.Deal', 'promote')).toBe(true);
		expect(canInManifest(manifest, 'crm.Deal', 'update')).toBe(false);
		expect(canInManifest(manifest, 'crm.Other', 'read')).toBe(false);
	});

	it('grants every action through an exact key holding *', () => {
		const manifest = { 'crm.Deal': ['*'] };
		expect(canInManifest(manifest, 'crm.Deal', 'delete')).toBe(true);
		expect(canInManifest(manifest, 'crm.Deal', 'promote')).toBe(true);
	});

	it('grants every doctype in a domain through the domain-wildcard key', () => {
		const manifest = { 'hr.*': ['read'] };
		expect(canInManifest(manifest, 'hr.Request', 'read')).toBe(true);
		expect(canInManifest(manifest, 'hr.Employee', 'read')).toBe(true);
		expect(canInManifest(manifest, 'crm.Deal', 'read')).toBe(false);
	});

	it('grants every action through a domain-wildcard key holding *', () => {
		const manifest = { 'hr.*': ['*'] };
		expect(canInManifest(manifest, 'hr.Request', 'delete')).toBe(true);
		expect(canInManifest(manifest, 'hr.Request', 'promote')).toBe(true);
		expect(canInManifest(manifest, 'crm.Deal', 'read')).toBe(false);
	});

	it('grants through the domain-wildcard key when the exact key lacks the action', () => {
		const manifest = { 'hr.*': ['read'], 'hr.Request': ['update'] };
		expect(canInManifest(manifest, 'hr.Request', 'read')).toBe(true);
		expect(canInManifest(manifest, 'hr.Request', 'update')).toBe(true);
	});

	it('does not suppress a domain-wildcard grant with *.*.except carve-outs', () => {
		// The carve-outs belong to the *.* line only — a domain-wide grant
		// stands on its own.
		const manifest = {
			'hr.*': ['read'],
			'*.*': ['read'],
			'*.*.except.read': ['hr.Request']
		};
		expect(canInManifest(manifest, 'hr.Request', 'read')).toBe(true);
	});

	it('consults the domain-wildcard key before the *.* fallback', () => {
		const manifest = { 'hr.*': ['read'], '*.*': ['update'] };
		expect(canInManifest(manifest, 'hr.Request', 'read')).toBe(true);
		expect(canInManifest(manifest, 'hr.Request', 'update')).toBe(true);
		expect(canInManifest(manifest, 'crm.Deal', 'read')).toBe(false);
	});

	it('falls back to the *.* action list when the exact key is absent', () => {
		const manifest = { '*.*': ['read'] };
		expect(canInManifest(manifest, 'crm.Deal', 'read')).toBe(true);
		expect(canInManifest(manifest, 'core.DocType.Comment', 'read')).toBe(true);
		expect(canInManifest(manifest, 'crm.Deal', 'update')).toBe(false);
	});

	it('falls back when the exact key is present but lacks the action', () => {
		// Editor shape: core.Domain holds update/delete explicitly; the read
		// still resolves through the wildcard line (this fixture keeps
		// core.Domain out of the carve-outs to isolate the fallback).
		const manifest = { '*.*': ['read', 'update'], 'core.Domain': ['update'] };
		expect(canInManifest(manifest, 'core.Domain', 'read')).toBe(true);
		expect(canInManifest(manifest, 'core.Domain', 'update')).toBe(true);
	});

	it('suppresses the fallback for an excepted doctype (exact entry)', () => {
		const manifest = { '*.*': ['read'], '*.*.except.read': ['core.SystemSettings'] };
		expect(canInManifest(manifest, 'core.SystemSettings', 'read')).toBe(false);
		expect(canInManifest(manifest, 'crm.Deal', 'read')).toBe(true);
	});

	it('suppresses the fallback for a prefix-excluded child doctype', () => {
		// An entry on core.DocType also excludes core.DocType.Comment — the
		// same prefix grammar the backend `except` uses.
		const manifest = { '*.*': ['read'], '*.*.except.read': ['core.DocType'] };
		expect(canInManifest(manifest, 'core.DocType', 'read')).toBe(false);
		expect(canInManifest(manifest, 'core.DocType.Comment', 'read')).toBe(false);
		expect(canInManifest(manifest, 'crm.Deal', 'read')).toBe(true);
	});

	it('keeps an explicit key grant even when the doctype is excepted', () => {
		// The carve-outs subtract from the wildcard line only — an explicit
		// re-grant on the same path stands (backend: pure path arithmetic,
		// not a deny system).
		const manifest = {
			'*.*': ['update'],
			'core.DocType': ['update'],
			'*.*.except.update': ['core.DocType']
		};
		expect(canInManifest(manifest, 'core.DocType', 'update')).toBe(true);
		expect(canInManifest(manifest, 'core.DocType', 'read')).toBe(false);
	});

	it('never falls back when the manifest has no wildcard key', () => {
		const manifest = { 'crm.Deal': ['update'] };
		expect(canInManifest(manifest, 'crm.Other', 'update')).toBe(false);
		expect(canInManifest(manifest, 'crm.Deal', 'read')).toBe(false);
	});

	it('grants the editor-role shape per backend carve-outs', () => {
		// core.Webhook: the exact key carries read/update/delete ($mine
		// re-grants); create resolves through the wildcard fallback — its
		// line does not subtract Webhook. The single-union shape denied this
		// create and hid the button (B-85).
		expect(canInManifest(EDITOR_MANIFEST, 'core.Webhook', 'create')).toBe(true);
		expect(canInManifest(EDITOR_MANIFEST, 'core.Webhook', 'update')).toBe(true);
		expect(canInManifest(EDITOR_MANIFEST, 'core.Webhook', 'read')).toBe(true);
		// core.Domain: update/delete ride the exact key; read resolves
		// through the wildcard — its line does not subtract Domain.
		expect(canInManifest(EDITOR_MANIFEST, 'core.Domain', 'update')).toBe(true);
		expect(canInManifest(EDITOR_MANIFEST, 'core.Domain', 'read')).toBe(true);
		// core.SystemSettings: excepted for every action, no exact key.
		expect(canInManifest(EDITOR_MANIFEST, 'core.SystemSettings', 'read')).toBe(false);
		expect(canInManifest(EDITOR_MANIFEST, 'core.SystemSettings', 'create')).toBe(false);
		// Ordinary content doctypes resolve through the fallback.
		expect(canInManifest(EDITOR_MANIFEST, 'crm.Deal', 'read')).toBe(true);
		expect(canInManifest(EDITOR_MANIFEST, 'crm.Deal', 'delete')).toBe(true);
	});

	it('ignores a legacy union-style *.*.except key', () => {
		// The matcher reads only the per-action reserved keys; a leftover
		// union key neither grants nor suppresses.
		const manifest = { '*.*': ['create'], '*.*.except': ['crm.Deal'] };
		expect(canInManifest(manifest, 'crm.Deal', 'create')).toBe(true);
	});

	// The exact checks the command palettes and sidebars place behind their
	// operator surfaces (the Configure palette's platform rows, the live
	// palette's page jumps, the NavPanel Configure row). The seeded roles
	// pin the visible/hidden outcome for every non-custom role.
	describe('palette gate markers (seeded-role shapes)', () => {
		const ADMIN_MANIFEST = { '*.*': ['*'] };

		it('shows the platform rows only where the role holds the gates', () => {
			// Section marker — `can('*.*', 'read')`. Coarse by design: the
			// literal `*.*` key grants without resolving the read carve-outs,
			// so a wildcard-read editor passes it (the sidebar shows the
			// section too, and `/Api/Indexes` + `/Api/Artifacts` are gated on
			// the generic `read *.*` the editor holds).
			expect(canInManifest(ADMIN_MANIFEST, '*.*', 'read')).toBe(true);
			expect(canInManifest(EDITOR_MANIFEST, '*.*', 'read')).toBe(true);
			expect(canInManifest(VIEWER_MANIFEST, '*.*', 'read')).toBe(true);
			// A role without a wildcard line never passes the marker.
			expect(canInManifest({ 'hr.*': ['read'] }, '*.*', 'read')).toBe(false);
		});

		it('keeps System settings admin-only', () => {
			// The item gate — `can('core.SystemSettings', 'read')`. The seed
			// carves the doctype out of the editor/viewer wildcard read, and
			// `/Api/SystemSettings` answers 403 without it.
			expect(canInManifest(ADMIN_MANIFEST, 'core.SystemSettings', 'read')).toBe(true);
			expect(canInManifest(EDITOR_MANIFEST, 'core.SystemSettings', 'read')).toBe(false);
			expect(canInManifest(VIEWER_MANIFEST, 'core.SystemSettings', 'read')).toBe(false);
		});

		it('gates the Configure jump on core.DocType update', () => {
			// The NavPanel Configure row's gate. The editor's `$domain_editor`
			// re-grants aggregate under the exact key; the viewer has no
			// update anywhere.
			expect(canInManifest(ADMIN_MANIFEST, 'core.DocType', 'update')).toBe(true);
			expect(canInManifest(EDITOR_MANIFEST, 'core.DocType', 'update')).toBe(true);
			expect(canInManifest(VIEWER_MANIFEST, 'core.DocType', 'update')).toBe(false);
		});
	});
});

describe('can (store-backed)', () => {
	afterEach(() => {
		setPermissions(null);
		clearPreviewSession();
	});

	it('delegates to canInManifest with the store manifest', () => {
		setPermissions(EDITOR_MANIFEST);
		expect(can('crm.Deal', 'read')).toBe(true);
		expect(can('core.SystemSettings', 'read')).toBe(false);
	});

	it('returns false with no manifest', () => {
		setPermissions(null);
		expect(can('crm.Deal', 'read')).toBe(false);
	});

	it('returns true for every check while a preview session is active', () => {
		setPermissions(null);
		setPreviewSession({
			draftId: '_abc',
			token: 'test-token',
			expiresAt: Math.floor(Date.now() / 1000) + 60
		});
		expect(can('crm.Deal', 'read')).toBe(true);
		expect(can('core.SystemSettings', 'delete')).toBe(true);
	});
});

describe('canScope (store-backed)', () => {
	afterEach(() => {
		setPermissions(null);
		setScopes(null);
	});

	it("returns 'denied' without a manifest", () => {
		setPermissions(null);
		expect(canScope('core.CollectionView', 'create')).toBe('denied');
	});

	it("returns 'unrestricted' on the admin wildcard", () => {
		setPermissions({ '*.*': ['*'] });
		setScopes({ '*.*': { create: ['mine'] } });
		expect(canScope('core.CollectionView', 'create')).toBe('unrestricted');
	});

	it("returns 'unrestricted' when no scope map is loaded", () => {
		setPermissions({ 'core.CollectionView': ['create'] });
		setScopes(null);
		expect(canScope('core.CollectionView', 'create')).toBe('unrestricted');
	});

	it("returns 'unrestricted' when the scope entry is absent", () => {
		setPermissions({ 'core.CollectionView': ['create'] });
		setScopes({ 'core.CollectionView': { update: ['mine'] } });
		expect(canScope('core.CollectionView', 'create')).toBe('unrestricted');
	});

	it('returns the alias list of an exact-key grant', () => {
		setPermissions({ 'core.CollectionView': ['create'] });
		setScopes({ 'core.CollectionView': { create: ['mine'] } });
		expect(canScope('core.CollectionView', 'create')).toEqual(['mine']);
	});

	it('resolves the wildcard-fallback scope from scopes["*.*"]', () => {
		setPermissions({ '*.*': ['create'] });
		setScopes({ '*.*': { create: ['mine'] } });
		expect(canScope('crm.Deal', 'create')).toEqual(['mine']);
	});

	it('resolves the domain-wildcard scope from scopes["hr.*"]', () => {
		setPermissions({ 'hr.*': ['create'] });
		setScopes({ 'hr.*': { create: ['mine'] } });
		expect(canScope('hr.Request', 'create')).toEqual(['mine']);
	});

	it("returns 'unrestricted' when the domain-wildcard grant has no scope entry", () => {
		setPermissions({ 'hr.*': ['create'] });
		setScopes({ 'crm.Deal': { create: ['mine'] } });
		expect(canScope('hr.Request', 'create')).toBe('unrestricted');
	});

	it("returns 'denied' when no exact, domain-wildcard, or *.* key grants", () => {
		setPermissions({ 'hr.*': ['read'], '*.*': ['update'] });
		setScopes({});
		expect(canScope('hr.Request', 'create')).toBe('denied');
	});

	it("returns 'unrestricted' when the wildcard fallback has no scope entry", () => {
		setPermissions({ '*.*': ['create'] });
		setScopes({ 'crm.Deal': { create: ['mine'] } });
		expect(canScope('crm.Deal', 'create')).toBe('unrestricted');
	});

	it("returns 'denied' when the wildcard fallback is suppressed by an except", () => {
		setPermissions({ '*.*': ['create'], '*.*.except.create': ['core.SystemSettings'] });
		setScopes({ '*.*': { create: ['mine'] } });
		expect(canScope('core.SystemSettings', 'create')).toBe('denied');
		expect(canScope('crm.Deal', 'create')).toEqual(['mine']);
	});

	it("returns 'denied' when an exact key lacks the action and the doctype is excepted", () => {
		setPermissions({
			'*.*': ['read', 'update'],
			'core.Domain': ['update'],
			'*.*.except.read': ['core.Domain']
		});
		setScopes({ '*.*': { read: [], update: [] } });
		expect(canScope('core.Domain', 'read')).toBe('denied');
		expect(canScope('core.Domain', 'update')).toBe('unrestricted');
	});

	it('resolves the editor webhook create as unrestricted through the fallback (B-85)', () => {
		// The exact $mine key lacks create; the wildcard fallback grants it
		// and reads the scope from scopes["*.*"] (unrestricted — the create
		// line holds no scope).
		setPermissions(EDITOR_MANIFEST);
		setScopes({
			'*.*': { create: [], update: [], delete: [], read: [] },
			'core.Webhook': { read: ['mine'], update: ['mine'], delete: ['mine'] }
		});
		// An empty alias list reads as unrestricted (the wildcard create line
		// holds no scope).
		expect(canScope('core.Webhook', 'create')).toEqual([]);
		expect(canScope('core.Webhook', 'update')).toEqual(['mine']);
	});
});

describe('fieldVisibleInTags', () => {
	afterEach(() => {
		setVisibleTags(null);
		clearPreviewSession();
	});

	// Mirrors `RBAC::FieldVisibility.field_visible?`: untagged fields need
	// only the `default` tag, multi-tag fields need every tag, `*` sees all.

	it('keeps an untagged field for a role with the default tag', () => {
		expect(fieldVisibleInTags(undefined, ['default'])).toBe(true);
		expect(fieldVisibleInTags(['default'], ['default'])).toBe(true);
	});

	it('drops a tagged field whose tag is outside the visible set', () => {
		expect(fieldVisibleInTags(['pay'], ['default'])).toBe(false);
	});

	it('needs every tag of a multi-tag field', () => {
		expect(fieldVisibleInTags(['pay', 'pii'], ['default', 'pay'])).toBe(false);
		expect(fieldVisibleInTags(['pay', 'pii'], ['default', 'pay', 'pii'])).toBe(true);
	});

	it('grants everything through the wildcard tag', () => {
		expect(fieldVisibleInTags(['pay'], ['*'])).toBe(true);
	});

	it('treats an empty tag list as untagged', () => {
		expect(fieldVisibleInTags([], ['default'])).toBe(true);
	});

	it('applies no filter when the set is not hydrated', () => {
		expect(fieldVisibleInTags(['pay'], null)).toBe(true);
		expect(fieldVisibleInTags(['pay'], undefined)).toBe(true);
	});
});

describe('fieldVisible (store-backed)', () => {
	afterEach(() => {
		setVisibleTags(null);
		clearPreviewSession();
	});

	it('reads the hydrated visible_tags store', () => {
		setVisibleTags(['default']);
		expect(fieldVisible({ tags: ['pay'] })).toBe(false);
		expect(fieldVisible({})).toBe(true);
	});

	it('applies no filter without a hydrated store', () => {
		setVisibleTags(null);
		expect(fieldVisible({ tags: ['pay'] })).toBe(true);
	});

	it('grants every check while a preview session is active', () => {
		setVisibleTags(['default']);
		setPreviewSession({
			draftId: '_abc',
			token: 'test-token',
			expiresAt: Math.floor(Date.now() / 1000) + 60
		});
		expect(fieldVisible({ tags: ['pay'] })).toBe(true);
	});
});
