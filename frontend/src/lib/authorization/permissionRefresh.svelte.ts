// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/** The window event the session layer dispatches after a token refresh or role switch. */
export const PERMISSIONS_UPDATE_EVENT = 'facet:permissions-update';

/**
 * Register a handler for the session permission-refresh signal, for the
 * component's whole lifetime.
 *
 * Must be called during component initialisation — it wraps a `$effect`,
 * which subscribes on mount and unsubscribes on destroy. The event is a
 * signal only: it carries no payload, and the handler should re-derive
 * everything it owns from the server (`invalidateAll()` plus any local
 * reload). See `session.svelte.ts` for the dispatch site.
 */
export function onPermissionRefresh(handler: () => void): void {
	$effect(() => {
		window.addEventListener(PERMISSIONS_UPDATE_EVENT, handler);
		return () => window.removeEventListener(PERMISSIONS_UPDATE_EVENT, handler);
	});
}
