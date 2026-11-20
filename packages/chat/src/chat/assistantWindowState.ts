// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Assistant window persistence for the chat package.
 *
 * The floating assistant is a collapsible window; its state persists in
 * session storage. Position is NOT persisted — the window resets to its
 * default inset each session to avoid drift bugs (off-screen after a
 * monitor change, etc.).
 *
 * Keys are package-owned (`facet.assistant.app.*`) so they can never collide
 * with the main application's own assistant (`facet.assistant.*`): both can
 * live in the same browser without reading each other's state.
 */

const STORAGE_KEY_OPEN = 'facet.assistant.app.open';
const STORAGE_KEY_COLLAPSED = 'facet.assistant.app.collapsed';
const STORAGE_KEY_MAXIMIZED = 'facet.assistant.app.maximized';
const STORAGE_KEY_RAIL_WIDTH = 'facet.assistant.app.rail-width';
const STORAGE_KEY_WIDTH = 'facet.assistant.app.width';
const STORAGE_KEY_HEIGHT = 'facet.assistant.app.height';

/**
 * Reads a boolean from sessionStorage. SSR-safe (no `window` on the
 * server) and access-safe (storage may be disabled in private mode —
 * any exception is swallowed and the default returned).
 */
function readBool(key: string, fallback: boolean): boolean {
	if (typeof window === 'undefined') return fallback;
	try {
		const v = window.sessionStorage.getItem(key);
		if (v === null) return fallback;
		return v === 'true';
	} catch {
		return fallback;
	}
}

/**
 * Writes a boolean to sessionStorage. Access-safe; failures (private mode,
 * quota) are silently dropped — the in-memory state still wins the UI.
 */
function writeBool(key: string, value: boolean): void {
	if (typeof window === 'undefined') return;
	try {
		window.sessionStorage.setItem(key, value ? 'true' : 'false');
	} catch {
		/* swallow */
	}
}

/**
 * Reads a number from sessionStorage. SSR-safe and access-safe (returns the
 * fallback when storage is unavailable or the stored value is not a finite
 * number within `[min, max]`, so a corrupt or out-of-range value never breaks
 * the layout).
 */
function readNumber(key: string, fallback: number, min: number, max: number): number {
	if (typeof window === 'undefined') return fallback;
	try {
		const v = window.sessionStorage.getItem(key);
		if (v === null) return fallback;
		const n = Number(v);
		if (!Number.isFinite(n)) return fallback;
		return Math.max(min, Math.min(max, n));
	} catch {
		return fallback;
	}
}

function writeNumber(key: string, value: number): void {
	if (typeof window === 'undefined') return;
	try {
		window.sessionStorage.setItem(key, String(value));
	} catch {
		/* swallow */
	}
}

/**
 * Reads the persisted open state of the floating window. Defaults to
 * **open**: a host that mounts the element explicitly asked for the
 * assistant, so the window is visible until the user (or the host, through
 * the element's `close()`) closes it — and only a close persists `false`.
 */
export function readAssistantOpen(): boolean {
	return readBool(STORAGE_KEY_OPEN, true);
}

export function writeAssistantOpen(value: boolean): void {
	writeBool(STORAGE_KEY_OPEN, value);
}

export function readAssistantCollapsed(): boolean {
	return readBool(STORAGE_KEY_COLLAPSED, false);
}

export function writeAssistantCollapsed(value: boolean): void {
	writeBool(STORAGE_KEY_COLLAPSED, value);
}

export function readAssistantMaximized(): boolean {
	return readBool(STORAGE_KEY_MAXIMIZED, false);
}

export function writeAssistantMaximized(value: boolean): void {
	writeBool(STORAGE_KEY_MAXIMIZED, value);
}

/** Conversation-rail width range (px). Kept tight so the rail never crowds the
 * chat column or collapses below a usable list width. */
export const RAIL_WIDTH_MIN = 160;
export const RAIL_WIDTH_MAX = 380;
export const RAIL_WIDTH_DEFAULT = 200;

export function readAssistantRailWidth(): number {
	return readNumber(STORAGE_KEY_RAIL_WIDTH, RAIL_WIDTH_DEFAULT, RAIL_WIDTH_MIN, RAIL_WIDTH_MAX);
}

export function writeAssistantRailWidth(value: number): void {
	writeNumber(STORAGE_KEY_RAIL_WIDTH, value);
}

/** Floating-window size range (px). MIN keeps the layout usable; MAX caps the
 * window so it never exceeds the viewport — clamped at read time against the
 * live viewport, so a size saved on a large monitor never overflows a smaller
 * one on the next session. */
export const WIN_WIDTH_MIN = 320;
export const WIN_HEIGHT_MIN = 240;
export const WIN_WIDTH_DEFAULT = 420;
export const WIN_HEIGHT_DEFAULT = 560;

export function readAssistantWidth(): number {
	return readNumber(STORAGE_KEY_WIDTH, WIN_WIDTH_DEFAULT, WIN_WIDTH_MIN, Infinity);
}

export function writeAssistantWidth(value: number): void {
	writeNumber(STORAGE_KEY_WIDTH, value);
}

export function readAssistantHeight(): number {
	return readNumber(STORAGE_KEY_HEIGHT, WIN_HEIGHT_DEFAULT, WIN_HEIGHT_MIN, Infinity);
}

export function writeAssistantHeight(value: number): void {
	writeNumber(STORAGE_KEY_HEIGHT, value);
}

/** Removes every persisted assistant key. Tests call this before mounting an
 * element so a suite never inherits window state from an earlier run. */
export function clearAssistantStorage(): void {
	if (typeof window === 'undefined') return;
	for (const key of [
		STORAGE_KEY_OPEN,
		STORAGE_KEY_COLLAPSED,
		STORAGE_KEY_MAXIMIZED,
		STORAGE_KEY_RAIL_WIDTH,
		STORAGE_KEY_WIDTH,
		STORAGE_KEY_HEIGHT
	]) {
		try {
			window.sessionStorage.removeItem(key);
		} catch {
			/* storage disabled — nothing to clear */
		}
	}
}
