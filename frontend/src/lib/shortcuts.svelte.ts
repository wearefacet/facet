// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Global keyboard shortcut system.
 *
 * One architecture, three parts:
 *
 * 1. **Registry** — the root layout registers the global scope (`Mod+I`,
 *    `Mod+\`, `?`); pages and heavy components (Table, DocumentForm)
 *    register route-scoped entries from an `$effect` and unregister through
 *    the returned cleanup, so route scope never leaks across navigations.
 * 2. **Dispatcher** — a single `keydown` listener on `window`, attached by
 *    the root layout with `<svelte:window>`. Route scope is matched before
 *    the global scope, so a page binding wins over the same key globally.
 * 3. **Cheat sheet** — `ShortcutsDialog.svelte` reads a fresh snapshot of
 *    the registry each time it opens (Bits UI mounts the dialog content per
 *    open) and renders every active entry under its group.
 *
 * Guard rails, in match order:
 *
 * - An event that is already `defaultPrevented` or inside IME composition
 *   is skipped, and so is any event whose target sits inside a modal dialog
 *   (`role="dialog"`) — Bits UI owns the keyboard there.
 * - Bare keys (no command/ctrl modifier) never fire while the focus sits in
 *   a typing target (input, textarea, select, contenteditable — CodeMirror
 *   included), with `Escape` as the only exception.
 * - Bare keys never fire with a command/ctrl modifier held: those combos
 *   belong to the browser or the OS (copy, paste, address bar, …).
 * - `Mod` is the platform key: ⌘ on macOS (⌃ stays native), Ctrl elsewhere.
 *   The opposite modifier never satisfies a `Mod` binding, and a `Mod`
 *   entry matches its own key only, without Shift/Alt — browser-reserved
 *   combos (`Ctrl+C` copy, `Ctrl+Shift+I` devtools) keep native behaviour.
 * - A held key only repeats when the entry opts in with `allowRepeat` —
 *   row navigation wants it, action shortcuts do not.
 *
 * Handlers return whether they acted; only then does the dispatcher call
 * `preventDefault`, so untouched keys keep their native behaviour (a
 * focused button's Enter click, a select's Escape).
 *
 * The registry holds **no signals at all** — plain arrays and plain
 * functions. Components register from `$effect`s; a signal write inside
 * those effects (any module-`$state` bump) proved to poison Svelte's update
 * graph and loop (`effect_update_depth_exceeded`). The dispatch path needs
 * no reactivity, and the cheat sheet re-reads the arrays on every open, so
 * nothing here ever writes state.
 */

/** Dialog section an entry renders under. */
export type ShortcutGroup = 'general' | 'list' | 'document';

export interface ShortcutEntry {
	/** Stable id within its scope — route scope dedupes on it. */
	id: string;
	/**
	 * Canonical key form: `Mod+K`, `C`, `?`, `/`, `Escape`, `Enter`,
	 * `ArrowDown`. `Mod` is the platform key (⌘ / Ctrl); a bare `+` in a key
	 * is not representable.
	 */
	keys: string;
	/** User-facing label — pass an already-resolved `m.*()` message. */
	label: string;
	/** Cheat-sheet section. */
	group: ShortcutGroup;
	/** True for keys that should keep firing while held (row navigation). */
	allowRepeat?: boolean;
	/**
	 * Extra gate, evaluated before the entry matches. Use it to skip the
	 * entry when the focus sits on a control that owns the key natively
	 * (an Enter on a focused button) or when the action has no target yet.
	 */
	when?: (e: KeyboardEvent) => boolean;
	/** Runs the action. Returns `true` when it acted (the event is prevented). */
	handler: (e: KeyboardEvent) => boolean;
}

interface ParsedKeys {
	/** `Mod+` prefix present. */
	mod: boolean;
	/** The literal key — single characters match case-insensitively. */
	key: string;
}

interface StoredEntry extends ShortcutEntry {
	parsed: ParsedKeys;
}

const globalEntries: StoredEntry[] = [];
const routeEntries: StoredEntry[] = [];

function parseKeys(keys: string): ParsedKeys {
	let mod = false;
	let key = '';
	for (const part of keys.split('+')) {
		if (part === 'Mod') mod = true;
		else key = part;
	}
	return { mod, key };
}

/**
 * The mod key glyph for key hints — ⌘ on Apple platforms, Ctrl elsewhere.
 * Also the label for the `Mod` token in `formatKeys`.
 */
export function modKeyLabel(): string {
	return isMacPlatform() ? '⌘' : 'Ctrl';
}

/** `Mod+K` → `['⌘', 'K']` or `['Ctrl', 'K']` — one entry per `<kbd>`. */
export function formatKeys(keys: string): string[] {
	return keys.split('+').map((part) => (part === 'Mod' ? modKeyLabel() : part));
}

/**
 * True on Apple platforms. `navigator.platform` is deprecated but still the
 * most consistent signal across browsers; the user agent widens the net for
 * iPad-on-desktop-ua. Defaults to non-mac (Ctrl) when neither exists (SSR).
 */
export function isMacPlatform(): boolean {
	if (typeof navigator === 'undefined') return false;
	const nav = navigator as { platform?: string; userAgent?: string };
	return /Mac|iPhone|iPad|iPod/.test(`${nav.platform ?? ''} ${nav.userAgent ?? ''}`);
}

function keyMatches(e: KeyboardEvent, parsed: ParsedKeys): boolean {
	if (parsed.mod) {
		// The platform mod must be the only command-style modifier held — the
		// opposite one keeps its native bindings (⌘C copy on macOS, Ctrl+C on
		// Windows/Linux must never satisfy or be consumed by a shortcut).
		// Shift and Alt keep the combo native too (Ctrl+Shift+I devtools,
		// browser windows, IME menus): the grammar has no Shift/Alt modifier,
		// so a `Mod+X` binding must never absorb `Mod+Shift+X` or `Mod+Alt+X`.
		if (e.shiftKey || e.altKey) return false;
		if (!(isMacPlatform() ? e.metaKey && !e.ctrlKey : e.ctrlKey && !e.metaKey)) return false;
	} else {
		// Bare keys never fire with a command modifier or Alt held — those
		// combos belong to the browser, the OS, or IME menus.
		if (e.metaKey || e.ctrlKey || e.altKey) return false;
	}
	// The entry fires on its own key only: a `Mod+I` binding must not match
	// every Ctrl-combo (an unbound Ctrl+C would otherwise be consumed by the
	// first registered Mod entry and never reach the browser's copy).
	if (parsed.key.length === 1) {
		// A produced character ('c', '?', '/') — shift-agnostic: the keyboard
		// layout already folded shift into `e.key` ('C' matches 'c').
		return e.key.toLowerCase() === parsed.key.toLowerCase();
	}
	// Named keys ('Escape', 'ArrowDown', 'Enter') match exactly and never
	// absorb shifted variants (Shift+ArrowDown keeps native text selection).
	return e.key === parsed.key && !e.shiftKey;
}

interface TypingTargetLike {
	tagName?: string;
	isContentEditable?: boolean;
}

/**
 * True when the focus sits where typing happens — inputs, textareas,
 * selects, and contenteditable surfaces (CodeMirror included). Bare-letter
 * shortcuts never fire from these targets.
 */
export function isTypingTarget(target: EventTarget | null): boolean {
	const t = target as TypingTargetLike | null;
	if (!t || typeof t.tagName !== 'string') return false;
	const tag = t.tagName.toUpperCase();
	return tag === 'INPUT' || tag === 'TEXTAREA' || tag === 'SELECT' || t.isContentEditable === true;
}

/**
 * True when the focus sits on a control that owns Enter/Space natively —
 * buttons, links, form widgets. Row-activation shortcuts skip these so a
 * focused toolbar button keeps its native click.
 */
export function isInteractiveTarget(target: EventTarget | null): boolean {
	if (typeof Element === 'undefined' || !(target instanceof Element)) return false;
	return (
		target.closest(
			'button, a[href], input, select, textarea, [contenteditable], [role="button"]'
		) !== null
	);
}

function withinDialog(target: EventTarget | null): boolean {
	// `Element` is absent in Node (SSR, unit tests) — nothing can match there.
	if (typeof Element === 'undefined' || !(target instanceof Element)) return false;
	return target.closest('[role="dialog"], [role="alertdialog"]') !== null;
}

/**
 * True when the focus sits inside an open dialog. Component-owned key
 * listeners (the command palette) read this to keep out of an open
 * dialog's keyboard space — the same guard the dispatcher applies.
 */
export function insideDialog(target: EventTarget | null): boolean {
	return withinDialog(target);
}

/**
 * True when the event carries exactly the platform `Mod` — no Shift, no
 * Alt, and not the opposite platform's command key. The same
 * command-modifier rule the dispatcher's `keyMatches` applies to registry
 * entries, shared with component-owned Mod-combo listeners.
 */
export function isModCombo(e: KeyboardEvent): boolean {
	if (e.shiftKey || e.altKey) return false;
	return isMacPlatform() ? e.metaKey && !e.ctrlKey : e.ctrlKey && !e.metaKey;
}

/**
 * Registers app-wide shortcuts. Call once from the root layout, inside an
 * `$effect` gated on authentication; the returned cleanup unregisters.
 */
export function registerGlobalShortcuts(entries: ShortcutEntry[]): () => void {
	const added = entries.map((entry) => ({ ...entry, parsed: parseKeys(entry.keys) }));
	globalEntries.push(...added);
	return () => {
		for (const stored of added) {
			const i = globalEntries.indexOf(stored);
			if (i >= 0) globalEntries.splice(i, 1);
		}
	};
}

/**
 * Registers the active page's shortcuts. Components call it from an
 * `$effect` and return the cleanup, so route scope unregisters on destroy
 * and never leaks across navigations. Duplicate ids are ignored — a second
 * Table on the page cannot double-bind the same key.
 */
export function registerRouteShortcuts(entries: ShortcutEntry[]): () => void {
	const added: StoredEntry[] = [];
	for (const entry of entries) {
		if (routeEntries.some((e) => e.id === entry.id)) continue;
		const stored: StoredEntry = { ...entry, parsed: parseKeys(entry.keys) };
		routeEntries.push(stored);
		added.push(stored);
	}
	return () => {
		for (const stored of added) {
			const i = routeEntries.indexOf(stored);
			if (i >= 0) routeEntries.splice(i, 1);
		}
	};
}

/**
 * Snapshot of every active entry, route scope first. Plain data — the cheat
 * sheet calls this when its content mounts, so each open lists the entries
 * registered at that moment.
 */
export function getRegisteredShortcuts(): ShortcutEntry[] {
	return [...routeEntries, ...globalEntries];
}

// ── Cheat-sheet open state ─────────────────────────────────────────────
//
// The one signal in this module — written only from event handlers (the
// `?` keydown, the Bits UI close), never from an effect. Same store pattern
// as `assistantOpen.svelte.ts`. The root layout's `?` handler opens the
// dialog; Bits UI writes back through `onOpenChange`.

let helpOpen = $state(false);

/** Whether the cheat-sheet dialog should mount. */
export function getShortcutsHelpOpen(): boolean {
	return helpOpen;
}

/** Opens or closes the cheat-sheet dialog. */
export function setShortcutsHelpOpen(value: boolean): void {
	helpOpen = value;
}

// ── Dispatcher ───────────────────────────────────────────────────────────

/**
 * The single keydown listener — attached by the root layout with
 * `<svelte:window onkeydown>`. Route scope is matched before the global
 * scope; the first entry that matches, passes its gates, and acts wins and
 * consumes the event.
 */
export function handleShortcutKeydown(e: KeyboardEvent): void {
	if (e.defaultPrevented || e.isComposing) return;
	// Inside a modal dialog Bits UI owns the keyboard — background actions
	// must not fire through it.
	if (withinDialog(e.target)) return;

	const typing = isTypingTarget(e.target);
	for (const entry of [...routeEntries, ...globalEntries]) {
		if (!keyMatches(e, entry.parsed)) continue;
		// Mod-combos and Escape work from typing targets; bare letters do not.
		if (typing && !entry.parsed.mod && entry.keys !== 'Escape') continue;
		if (e.repeat && !entry.allowRepeat) continue;
		if (entry.when && !entry.when(e)) continue;
		if (entry.handler(e)) {
			e.preventDefault();
			return;
		}
	}
}
