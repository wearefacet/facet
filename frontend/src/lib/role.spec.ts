// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect, afterEach, vi } from 'vitest';
import { setRole, getActiveRole, getAvailableRoles, activeRoleLabel } from './role.svelte.js';

/**
 * Unit tests for the reactive role store.
 *
 * In Node (no `window`) the store exercises its SSR branch: reads/writes gate on
 * the browser, so `setRole` is a no-op and the getters report the SSR-safe
 * defaults (`null`). `availableRoles` starts as `null` (not yet hydrated) so
 * callers can distinguish "unknown" from a genuinely empty role list and opt
 * into the server snapshot as a fallback.
 */

describe('role store — SSR safety (Node environment)', () => {
	it('getters default to null on the server', () => {
		expect(getActiveRole()).toBeNull();
		expect(getAvailableRoles()).toBeNull();
	});

	it('setRole is a no-op on the server (state stays default)', () => {
		setRole('iam.Roles.admin', ['iam.Roles.admin', 'iam.Roles.editor']);
		expect(getActiveRole()).toBeNull();
		expect(getAvailableRoles()).toBeNull();
	});
});

describe('role store — hydration (window defined)', () => {
	afterEach(() => {
		// Restore the original window (may be undefined in Node) so later tests
		// run in their usual environment.
		vi.unstubAllGlobals();
	});

	it('starts with null roles, then exposes them after setRole', () => {
		// `setRole` gates on `typeof window === 'undefined'`; a defined `window`
		// exercises the browser (hydration) branch.
		vi.stubGlobal('window', {});
		expect(getActiveRole()).toBeNull();
		expect(getAvailableRoles()).toBeNull();

		setRole('iam.Roles.admin', ['iam.Roles.admin', 'iam.Roles.editor']);
		expect(getActiveRole()).toBe('iam.Roles.admin');
		expect(getAvailableRoles()).toEqual(['iam.Roles.admin', 'iam.Roles.editor']);
	});

	it('coerces a missing available list to an empty array on hydration', () => {
		vi.stubGlobal('window', {});
		setRole('iam.Roles.admin', undefined);
		expect(getAvailableRoles()).toEqual([]);
	});
});

describe('role store — activeRoleLabel', () => {
	it('extracts and humanizes the trailing segment of a role id', () => {
		expect(activeRoleLabel('iam.Roles.admin')).toBe('Admin');
	});

	it('humanizes snake_case role names', () => {
		expect(activeRoleLabel('iam.Roles.production_editor')).toBe('Production Editor');
	});

	it('returns the id unchanged when there is no dot', () => {
		expect(activeRoleLabel('admin')).toBe('Admin');
	});
});
