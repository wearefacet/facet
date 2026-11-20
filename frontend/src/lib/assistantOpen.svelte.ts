// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Assistant open state — one flag drives both assistant surfaces.
 *
 * The builder's floating window (mount on /Builder) and the workspace's
 * window (mount on the live routes, gated on `assistantAccess` from
 * `/Api/iam/me`) both read this flag; it persists in sessionStorage under
 * `facet.assistant.open`, so the assistant stays open as the user moves
 * between the builder and the live app. Configure (own shell) and the OAuth
 * consent page (bare page) render neither surface. Visibility is owned
 * here — the toggles are the only entry points; collapse state lives inside
 * the window shell.
 *
 * Mirrors the pattern of `theme.svelte.ts`: module-level `$state`, getter
 * and setter functions, no `setContext`.
 */

const STORAGE_KEY = 'facet.assistant.open';

let open = $state(false);

/** Whether the assistant window should mount. */
export function getAssistantOpen(): boolean {
	return open;
}

/**
 * Hydrates the open state from sessionStorage. SSR runs without storage;
 * the value defaults to closed there and syncs on the first client run.
 * Call once from the root layout.
 */
export function initAssistantOpen(): void {
	if (typeof window === 'undefined') return;
	try {
		open = window.sessionStorage.getItem(STORAGE_KEY) === 'true';
	} catch {
		open = false;
	}
}

/**
 * Sets the open state and persists it. A failed write (storage disabled in
 * private mode) keeps the in-memory state — the flag survives the session
 * only.
 */
export function setAssistantOpen(value: boolean): void {
	open = value;
	if (typeof window === 'undefined') return;
	try {
		window.sessionStorage.setItem(STORAGE_KEY, value ? 'true' : 'false');
	} catch {
		/* storage disabled (private mode) — swallow */
	}
}

/** Flips the open state and persists it. */
export function toggleAssistantOpen(): void {
	setAssistantOpen(!open);
}
