// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Reactive theme store — light/dark, persisted to `localStorage`.
 *
 * Mirrors the pattern of `permissions.svelte.ts` and `session.svelte.ts`:
 * module-level `$state`, getter/setter functions, no `setContext`.
 *
 * The `<html data-theme>` attribute is the source of truth consumed by the
 * token CSS in `tokens.css`. An inline script in `app.html` applies the
 * stored theme before first paint to prevent a flash of the wrong theme.
 */

export type Theme = 'light' | 'dark';

const STORAGE_KEY = 'facet:theme';

let theme: Theme | null = $state(null);

function systemPreference(): Theme {
	if (typeof window === 'undefined') return 'light';
	return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
}

function applyToDom(value: Theme): void {
	if (typeof document !== 'undefined') {
		document.documentElement.setAttribute('data-theme', value);
	}
}

/**
 * Initialise the store from `localStorage` (or the system preference as a
 * fallback). Safe to call only in the browser — `+layout.svelte` invokes it
 * on mount.
 */
export function initTheme(): void {
	if (theme !== null) return;
	const stored = typeof localStorage !== 'undefined' ? localStorage.getItem(STORAGE_KEY) : null;
	const initial: Theme = stored === 'dark' || stored === 'light' ? stored : systemPreference();
	theme = initial;
	applyToDom(initial);
}

export function getTheme(): Theme {
	return theme ?? 'light';
}

export function setTheme(value: Theme): void {
	theme = value;
	if (typeof localStorage !== 'undefined') localStorage.setItem(STORAGE_KEY, value);
	applyToDom(value);
}

/** Toggles between light and dark. */
export function toggleTheme(): void {
	setTheme(getTheme() === 'dark' ? 'light' : 'dark');
}
