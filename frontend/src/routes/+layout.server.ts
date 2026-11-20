// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { LayoutServerLoad } from './$types';

/**
 * Forwards the session resolved by `handleAuth` in `hooks.server.ts` to the
 * universal `+layout.ts`. Keeping this in a server load (rather than reading
 * `locals` from the universal load, which cannot) lets the universal load stay
 * free of `url` dependencies so it does not re-run on client-side navigation.
 */
export const load: LayoutServerLoad = async ({ locals }) => {
	return {
		account: locals.account,
		activeRole: locals.activeRole,
		availableRoles: locals.availableRoles,
		authenticated: locals.authenticated,
		assistantAccess: locals.assistantAccess,
		assistantConfigured: locals.assistantConfigured,
		assistantName: locals.assistantName,
		connectivity: locals.connectivity,
		permissions: locals.permissions,
		scopes: locals.scopes,
		visibleTags: locals.visibleTags,
		expiresAt: locals.expiresAt,
		// Mirrors the cookie-read preview session to the universal `+layout.ts`
		// so a full reload of `/_abc` re-injects the preview principal before
		// any SSR `apiFetch` call. Null when no preview is active.
		previewSession: locals.previewSession
	};
};
