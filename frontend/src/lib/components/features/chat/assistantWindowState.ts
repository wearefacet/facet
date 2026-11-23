// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Assistant window persistence (configure/builder UX brief addendum).
 *
 * Per the brief: the assistant is a floating, collapsible window; its
 * open/close state persists in local session storage. The expanded window
 * keeps its position session-local — it resets to its default inset each
 * session to avoid drift bugs (off-screen after a monitor change, etc.).
 * The collapsed bar persists its position and width instead, so the bar
 * reopens where the user left it.
 *
 * One window design serves every mount (builder and workspace), so the
 * keys are shared: the surfaces never mount at the same time.
 *
 * Keys are namespaced under `facet.assistant.*` so future persisted
 * assistant state (e.g. per-domain collapse, draft-scoped last-conversation)
 * can extend without collisions.
 */

const STORAGE_KEY_OPEN = 'facet.assistant.open';
const STORAGE_KEY_COLLAPSED = 'facet.assistant.collapsed';
const STORAGE_KEY_MAXIMIZED = 'facet.assistant.maximized';
const STORAGE_KEY_RAIL_WIDTH = 'facet.assistant.rail-width';
const STORAGE_KEY_WIDTH = 'facet.assistant.width';
const STORAGE_KEY_HEIGHT = 'facet.assistant.height';
const STORAGE_KEY_BAR_X = 'facet.assistant.bar-x';
const STORAGE_KEY_BAR_Y = 'facet.assistant.bar-y';
const STORAGE_KEY_BAR_WIDTH = 'facet.assistant.bar-width';

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
 * Reads a stored number that may be unset. Returns `null` when the key is
 * absent or the stored value is not a finite number — the caller then
 * keeps its computed default. SSR-safe and access-safe.
 */
function readNumberOrNull(key: string): number | null {
	if (typeof window === 'undefined') return null;
	try {
		const v = window.sessionStorage.getItem(key);
		if (v === null) return null;
		const n = Number(v);
		return Number.isFinite(n) ? n : null;
	} catch {
		return null;
	}
}

export function readAssistantOpen(): boolean {
	return readBool(STORAGE_KEY_OPEN, false);
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

/** Collapsed-bar geometry (px). The bar keeps the 40 px header height; only
 * its position and width move. WIDTH_MIN keeps the title and the header
 * buttons readable; there is no fixed maximum — the component clamps the
 * rendered geometry against the live viewport. */
export const BAR_WIDTH_MIN = 200;

/**
 * Reads the persisted collapsed-bar position axis. `null` = unset — the
 * bar then starts docked at the bottom edge, at the floating window's x.
 */
export function readAssistantBarX(): number | null {
	return readNumberOrNull(STORAGE_KEY_BAR_X);
}

export function writeAssistantBarX(value: number): void {
	writeNumber(STORAGE_KEY_BAR_X, value);
}

export function readAssistantBarY(): number | null {
	return readNumberOrNull(STORAGE_KEY_BAR_Y);
}

export function writeAssistantBarY(value: number): void {
	writeNumber(STORAGE_KEY_BAR_Y, value);
}

/** Reads the persisted collapsed-bar width. `null` = unset — the bar then
 * inherits the floating window's width. A stored width clamps up to
 * `BAR_WIDTH_MIN`, so a corrupt value never shrinks the bar unreadable. */
export function readAssistantBarWidth(): number | null {
	const v = readNumberOrNull(STORAGE_KEY_BAR_WIDTH);
	if (v === null) return null;
	return Math.max(BAR_WIDTH_MIN, v);
}

export function writeAssistantBarWidth(value: number): void {
	writeNumber(STORAGE_KEY_BAR_WIDTH, value);
}

/** Removes every persisted assistant key. Stories call this before a mount
 * so a play function never inherits window state from an earlier run. */
export function clearAssistantStorage(): void {
	if (typeof window === 'undefined') return;
	for (const key of [
		STORAGE_KEY_OPEN,
		STORAGE_KEY_COLLAPSED,
		STORAGE_KEY_MAXIMIZED,
		STORAGE_KEY_RAIL_WIDTH,
		STORAGE_KEY_WIDTH,
		STORAGE_KEY_HEIGHT,
		STORAGE_KEY_BAR_X,
		STORAGE_KEY_BAR_Y,
		STORAGE_KEY_BAR_WIDTH
	]) {
		try {
			window.sessionStorage.removeItem(key);
		} catch {
			/* storage disabled — nothing to clear */
		}
	}
}
