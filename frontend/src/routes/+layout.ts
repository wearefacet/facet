// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { LayoutLoad } from './$types';
import { buildNavModel } from '$lib/navModel';
import type { NavDomain } from '$lib/navTypes';
import { setPermissions, setScopes, setVisibleTags } from '$lib/permissions.svelte';
import { setExpiresAt } from '$lib/session.svelte';
import { setRole } from '$lib/role.svelte';
import { DocumentDataDriver } from '$lib/datasource/DocumentDriver';
import { isPreviewActive, setPreviewSession } from '$lib/previewSession.svelte';

/**
 * Universal root layout load.
 *
 * Hydrates the client-side permission/expiry stores from the session resolved
 * by `handleAuth` (forwarded via `+layout.server.ts`), then builds the live nav
 * model.
 *
 * This load intentionally reads **no** `url`/`params` properties. Per SvelteKit's
 * dependency tracking, accessing `url` would cause this load to re-run on every
 * navigation — re-fetching the nav model and producing the tab-switch flicker.
 * The session itself is validated in `hooks.server.ts` (on every server
 * request), not here, so client-side navigations stay instant.
 *
 * Preview overlay: when a preview capability token is active (issued by the
 * Builder Preview toggle), the regular permission manifest from `data` is
 * suppressed — preview's `Principal::Preview` authorises every read on the
 * bound draft's doctypes, so manifest filtering would hide them incorrectly.
 */
export const load: LayoutLoad = async ({ data, fetch }) => {
	setExpiresAt(data.expiresAt);
	setRole(data.activeRole, data.availableRoles);

	// SSR preview hydration: on a full reload of `/_abc` during preview, the
	// in-memory `previewSession` store is null (sessionStorage is not yet
	// hydrated when this load runs on the server). The hook mirrored the
	// cookie-set preview state to `data.previewSession`; re-inject it here so
	// the `apiFetch` overlay below (and the nav-model build following) see
	// the preview principal. On the client, the store is already hydrated
	// from `sessionStorage` before this load runs — the `isPreviewActive`
	// guard below prevents clobbering an active session with a stale or
	// absent server-side value.
	if (!isPreviewActive() && data.previewSession) {
		setPreviewSession(data.previewSession);
	}
	const preview = isPreviewActive();
	const effectivePermissions = preview ? undefined : (data.permissions ?? undefined);
	if (!preview) setPermissions(data.permissions);
	setScopes(data.scopes);
	// Field-tag visibility (B-176). Set unconditionally: the predicate
	// fail-opens under a preview session, mirroring `can()`.
	setVisibleTags(data.visibleTags);

	// Skip nav model build for unauthenticated requests (e.g. /login) — the
	// backend returns 401 for API calls without a valid session, and
	// DocumentDataSource would throw instead of returning empty. A roleless
	// account (B-120) is authenticated but has no workspace — the layout
	// renders `NoRoleScreen`, so its nav model is not built either.
	let domains: NavDomain[] = [];
	if (data.authenticated && (data.availableRoles?.length ?? 0) > 0) {
		// SSR-safe driver: pass SvelteKit's `event.fetch` so relative URLs resolve
		// during server-side rendering (full page load).
		const ssrDriver = new DocumentDataDriver('', fetch);
		domains = await buildNavModel(ssrDriver, effectivePermissions);
	}

	return {
		domains,
		account: data.account,
		activeRole: data.activeRole,
		availableRoles: data.availableRoles,
		authenticated: data.authenticated,
		// Workspace-assistant availability (`me.assistant.access`), forwarded
		// for the dock mount + top-bar toggle gating in `+layout.svelte`, and
		// the configured assistant display name (`me.assistant.name`) every
		// assistant surface renders. `assistantConfigured` (`me.assistant
		// .configured`) reports whether an API key resolves installation-wide —
		// false keeps the dock visible but disables conversation creation.
		assistantAccess: data.assistantAccess,
		assistantConfigured: data.assistantConfigured ?? false,
		assistantName: data.assistantName ?? 'Assistant',
		// The active role's connectivity channels (`me.connectivity`) — the
		// per-role programmatic-channel list the affordance gates read.
		connectivity: data.connectivity ?? []
	};
};
