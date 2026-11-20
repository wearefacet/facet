// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect, vi, afterEach } from 'vitest';
import { switchActiveRole } from './auth.svelte.js';
import { setExpiresAt } from './session.svelte.js';

/**
 * Unit tests for the frontend role-switch action.
 *
 * These run in Node (no `window`), which exercises the SSR branch of the role
 * store: `setRole` / `setPermissions` / `setScopes` are no-ops and
 * `invalidateAll()` is skipped (the success path gates it on
 * `typeof window !== 'undefined'`). The core contract asserted here is the
 * request itself — a role-bearing refresh POST — and the success/failure
 * return value. The fixture includes both `permissions` and `scopes` so a
 * future browser-environment test (or a refactor that drops the `window`
 * gate) would also exercise the scopes-forwarding branch.
 */

const REFRESH_URL = '/Api/iam/refresh';

function jsonResponse(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'Content-Type': 'application/json' }
	});
}

describe('switchActiveRole', () => {
	afterEach(() => {
		setExpiresAt(null);
	});

	it('POSTs a role-bearing refresh and returns true on success', async () => {
		const fetchFn = vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
			const url = typeof input === 'string' ? input : input.toString();
			expect(url).toBe(REFRESH_URL);
			expect(init?.method).toBe('POST');
			const body = JSON.parse(String(init?.body));
			expect(body).toEqual({ cookie: true, role: 'iam.Roles.editor' });
			return jsonResponse({
				active_role: 'iam.Roles.editor',
				available_roles: ['iam.Roles.admin', 'iam.Roles.editor'],
				expires_at: Math.floor(Date.now() / 1000) + 900,
				permissions: { 'crm.Company': ['read', 'update'] },
				scopes: { 'crm.Company': { update: ['mine'] } }
			});
		});

		const ok = await switchActiveRole('iam.Roles.editor', fetchFn);
		expect(ok).toBe(true);
		expect(fetchFn).toHaveBeenCalledTimes(1);
	});

	it('returns false when the backend rejects the switch', async () => {
		const fetchFn = vi.fn(async () => jsonResponse({ error: 'Role not assigned' }, 403));
		const ok = await switchActiveRole('iam.Roles.editor', fetchFn);
		expect(ok).toBe(false);
	});
});
