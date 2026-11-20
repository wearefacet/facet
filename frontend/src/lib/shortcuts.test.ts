// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import {
	formatKeys,
	getRegisteredShortcuts,
	handleShortcutKeydown,
	isTypingTarget,
	modKeyLabel,
	registerGlobalShortcuts,
	registerRouteShortcuts,
	setShortcutsHelpOpen,
	getShortcutsHelpOpen
} from './shortcuts.svelte';

/**
 * Unit tests for the shortcut registry and dispatcher. These run in Node
 * (no `window`, no `Element`), so the guard helpers are exercised with
 * duck-typed targets and the dispatcher with synthetic KeyboardEvent-like
 * objects. `isMacPlatform` is pinned per test through a `navigator` stub —
 * the mod-key resolution is the platform-sensitive branch.
 */

/** Minimal keyboard-event stand-in for the dispatcher tests. */
function makeKeyEvent(init: {
	key: string;
	metaKey?: boolean;
	ctrlKey?: boolean;
	shiftKey?: boolean;
	altKey?: boolean;
	isComposing?: boolean;
	target?: unknown;
	defaultPrevented?: boolean;
	repeat?: boolean;
}): { event: KeyboardEvent; prevented: () => number } {
	let prevented = 0;
	const event = {
		key: init.key,
		metaKey: init.metaKey ?? false,
		ctrlKey: init.ctrlKey ?? false,
		shiftKey: init.shiftKey ?? false,
		altKey: init.altKey ?? false,
		isComposing: init.isComposing ?? false,
		repeat: init.repeat ?? false,
		defaultPrevented: init.defaultPrevented ?? false,
		target: init.target ?? {},
		preventDefault: () => {
			prevented += 1;
		}
	} as unknown as KeyboardEvent;
	return { event, prevented: () => prevented };
}

/** Pin the platform resolution for the current test. */
function stubNavigator(platform: string) {
	vi.stubGlobal('navigator', { platform });
}

beforeEach(() => {
	stubNavigator('Linux x86_64');
	setShortcutsHelpOpen(false);
});

afterEach(() => {
	vi.unstubAllGlobals();
});

describe('modKeyLabel', () => {
	it('returns Ctrl on non-mac platforms', () => {
		stubNavigator('Linux x86_64');
		expect(modKeyLabel()).toBe('Ctrl');
	});

	it('returns ⌘ on mac platforms', () => {
		stubNavigator('MacIntel');
		expect(modKeyLabel()).toBe('⌘');
	});

	it('detects mac through the user agent when platform is missing', () => {
		vi.stubGlobal('navigator', { userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X)' });
		expect(modKeyLabel()).toBe('⌘');
	});

	it('defaults to Ctrl without a navigator (SSR)', () => {
		vi.unstubAllGlobals();
		expect(modKeyLabel()).toBe('Ctrl');
	});
});

describe('formatKeys', () => {
	it('splits on + and renders the platform mod', () => {
		stubNavigator('Win32');
		expect(formatKeys('Mod+K')).toEqual(['Ctrl', 'K']);
	});

	it('passes bare keys through', () => {
		expect(formatKeys('C')).toEqual(['C']);
		expect(formatKeys('?')).toEqual(['?']);
	});
});

describe('isTypingTarget', () => {
	it('accepts input, textarea, select and contenteditable', () => {
		expect(isTypingTarget({ tagName: 'INPUT' } as unknown as EventTarget)).toBe(true);
		expect(isTypingTarget({ tagName: 'TEXTAREA' } as unknown as EventTarget)).toBe(true);
		expect(isTypingTarget({ tagName: 'SELECT' } as unknown as EventTarget)).toBe(true);
		expect(
			isTypingTarget({ tagName: 'DIV', isContentEditable: true } as unknown as EventTarget)
		).toBe(true);
	});

	it('rejects non-typing targets and null', () => {
		expect(isTypingTarget({ tagName: 'BUTTON' } as unknown as EventTarget)).toBe(false);
		expect(isTypingTarget({ tagName: 'BODY' } as unknown as EventTarget)).toBe(false);
		expect(isTypingTarget(null)).toBe(false);
		expect(isTypingTarget({} as EventTarget)).toBe(false);
	});
});

describe('registry', () => {
	it('registers and unregisters route entries idempotently', () => {
		const handler = () => false;
		const unregister = registerRouteShortcuts([
			{ id: 't.a', keys: 'C', label: 'A', group: 'list', handler }
		]);
		expect(getRegisteredShortcuts()).toHaveLength(1);

		unregister();
		expect(getRegisteredShortcuts()).toHaveLength(0);
	});

	it('dedupes route registrations on id (first wins)', () => {
		const first = registerRouteShortcuts([
			{ id: 't.a', keys: 'C', label: 'First', group: 'list', handler: () => false }
		]);
		const second = registerRouteShortcuts([
			{ id: 't.a', keys: 'C', label: 'Second', group: 'list', handler: () => false }
		]);
		expect(getRegisteredShortcuts()).toHaveLength(1);
		expect(getRegisteredShortcuts()[0].label).toBe('First');

		first();
		// The deduped registration registered nothing — its cleanup is a no-op.
		second();
		expect(getRegisteredShortcuts()).toHaveLength(0);
	});

	it('keeps global and route scopes independent', () => {
		const unGlobal = registerGlobalShortcuts([
			{ id: 'g.a', keys: 'Mod+I', label: 'G', group: 'general', handler: () => false }
		]);
		const unRoute = registerRouteShortcuts([
			{ id: 'r.a', keys: 'C', label: 'R', group: 'list', handler: () => false }
		]);
		// Route scope first — the cheat sheet renders page entries on top.
		expect(getRegisteredShortcuts().map((e) => e.id)).toEqual(['r.a', 'g.a']);

		unRoute();
		unGlobal();
		expect(getRegisteredShortcuts()).toHaveLength(0);
	});
});

describe('handleShortcutKeydown', () => {
	it('fires a bare-key route entry and prevents the default', () => {
		let fired = 0;
		const unregister = registerRouteShortcuts([
			{
				id: 't.new',
				keys: 'C',
				label: 'New',
				group: 'list',
				handler: () => {
					fired += 1;
					return true;
				}
			}
		]);

		const { event, prevented } = makeKeyEvent({ key: 'c' });
		handleShortcutKeydown(event);
		expect(fired).toBe(1);
		expect(prevented()).toBe(1);

		unregister();
	});

	it('matches single-char keys case-insensitively and shift-agnostically', () => {
		let fired = 0;
		const unregister = registerRouteShortcuts([
			{
				id: 't.new',
				keys: 'C',
				label: 'New',
				group: 'list',
				handler: () => {
					fired += 1;
					return true;
				}
			}
		]);

		handleShortcutKeydown(makeKeyEvent({ key: 'C' }).event);
		handleShortcutKeydown(makeKeyEvent({ key: 'C', shiftKey: true }).event);
		expect(fired).toBe(2);

		unregister();
	});

	it('never fires a bare key while a command modifier is held', () => {
		let fired = 0;
		const unregister = registerRouteShortcuts([
			{
				id: 't.new',
				keys: 'C',
				label: 'New',
				group: 'list',
				handler: () => {
					fired += 1;
					return true;
				}
			}
		]);

		// Ctrl+C on Linux — the native copy combo must not trigger 'C'.
		handleShortcutKeydown(makeKeyEvent({ key: 'c', ctrlKey: true }).event);
		// Meta+C too (Windows key / mac Ctrl — both reserved for the OS).
		handleShortcutKeydown(makeKeyEvent({ key: 'c', metaKey: true }).event);
		expect(fired).toBe(0);

		unregister();
	});

	it('resolves Mod per platform and never through the opposite modifier', () => {
		const fired: string[] = [];
		const unregister = registerGlobalShortcuts([
			{
				id: 'g.assistant',
				keys: 'Mod+I',
				label: 'Assistant',
				group: 'general',
				handler: () => {
					fired.push('assistant');
					return true;
				}
			}
		]);

		// Linux: Ctrl+I fires, Meta+I does not.
		stubNavigator('Linux x86_64');
		handleShortcutKeydown(makeKeyEvent({ key: 'i', ctrlKey: true }).event);
		handleShortcutKeydown(makeKeyEvent({ key: 'i', metaKey: true }).event);
		expect(fired).toEqual(['assistant']);

		// Mac: ⌘I fires (Ctrl stays native), Ctrl+I does not.
		stubNavigator('MacIntel');
		handleShortcutKeydown(makeKeyEvent({ key: 'i', metaKey: true }).event);
		handleShortcutKeydown(makeKeyEvent({ key: 'i', ctrlKey: true }).event);
		expect(fired).toEqual(['assistant', 'assistant']);

		unregister();
	});

	it('consumes only its own key — unbound Ctrl-combos stay native', () => {
		let fired = 0;
		const unregister = registerGlobalShortcuts([
			{
				id: 'g.assistant',
				keys: 'Mod+I',
				label: 'Assistant',
				group: 'general',
				handler: () => {
					fired += 1;
					return true;
				}
			}
		]);

		// Ctrl+C (copy) matches no entry — nothing fires, nothing is prevented.
		const copy = makeKeyEvent({ key: 'c', ctrlKey: true });
		handleShortcutKeydown(copy.event);
		expect(fired).toBe(0);
		expect(copy.prevented()).toBe(0);

		unregister();
	});

	it('keeps Shift and Alt variants of a Mod key native (devtools, IME)', () => {
		let fired = 0;
		const unregister = registerGlobalShortcuts([
			{
				id: 'g.assistant',
				keys: 'Mod+I',
				label: 'Assistant',
				group: 'general',
				handler: () => {
					fired += 1;
					return true;
				}
			}
		]);

		// Ctrl+Shift+I opens the browser devtools — the app must not consume it.
		const devtools = makeKeyEvent({ key: 'I', ctrlKey: true, shiftKey: true });
		handleShortcutKeydown(devtools.event);
		// Ctrl+Alt+… stays native too (AltGr, IME menus).
		const altCombo = makeKeyEvent({ key: 'i', ctrlKey: true, altKey: true });
		handleShortcutKeydown(altCombo.event);
		expect(fired).toBe(0);
		expect(devtools.prevented()).toBe(0);
		expect(altCombo.prevented()).toBe(0);

		// The plain combo still fires.
		handleShortcutKeydown(makeKeyEvent({ key: 'i', ctrlKey: true }).event);
		expect(fired).toBe(1);

		unregister();
	});

	it('skips bare keys while typing, but allows mod-combos and Escape', () => {
		const fired: string[] = [];
		const typingInput = { tagName: 'INPUT' };
		const unregister = registerRouteShortcuts([
			{
				id: 't.new',
				keys: 'C',
				label: 'New',
				group: 'list',
				handler: () => {
					fired.push('new');
					return true;
				}
			},
			{
				id: 't.save',
				keys: 'Mod+S',
				label: 'Save',
				group: 'document',
				handler: () => {
					fired.push('save');
					return true;
				}
			},
			{
				id: 't.clear',
				keys: 'Escape',
				label: 'Clear',
				group: 'list',
				handler: () => {
					fired.push('clear');
					return true;
				}
			}
		]);

		handleShortcutKeydown(makeKeyEvent({ key: 'c', target: typingInput }).event);
		handleShortcutKeydown(makeKeyEvent({ key: 's', ctrlKey: true, target: typingInput }).event);
		handleShortcutKeydown(makeKeyEvent({ key: 'Escape', target: typingInput }).event);
		expect(fired).toEqual(['save', 'clear']);

		unregister();
	});

	it('skips Escape when a when-gate rejects the entry', () => {
		let fired = 0;
		const unregister = registerRouteShortcuts([
			{
				id: 't.clear',
				keys: 'Escape',
				label: 'Clear',
				group: 'list',
				when: () => false,
				handler: () => {
					fired += 1;
					return true;
				}
			}
		]);

		const { event, prevented } = makeKeyEvent({ key: 'Escape' });
		handleShortcutKeydown(event);
		expect(fired).toBe(0);
		// A skipped entry must not consume the key — the native Escape keeps working.
		expect(prevented()).toBe(0);

		unregister();
	});

	it('blocks repeat for action keys and allows it for allowRepeat entries', () => {
		let navigation = 0;
		let create = 0;
		const unregister = registerRouteShortcuts([
			{
				id: 't.next',
				keys: 'j',
				label: 'Next',
				group: 'list',
				allowRepeat: true,
				handler: () => {
					navigation += 1;
					return true;
				}
			},
			{
				id: 't.new',
				keys: 'C',
				label: 'New',
				group: 'list',
				handler: () => {
					create += 1;
					return true;
				}
			}
		]);

		handleShortcutKeydown(makeKeyEvent({ key: 'j', repeat: true }).event);
		handleShortcutKeydown(makeKeyEvent({ key: 'c', repeat: true }).event);
		expect(navigation).toBe(1);
		expect(create).toBe(0);

		unregister();
	});

	it('ignores already-prevented events and IME composition', () => {
		let fired = 0;
		const unregister = registerRouteShortcuts([
			{
				id: 't.new',
				keys: 'C',
				label: 'New',
				group: 'list',
				handler: () => {
					fired += 1;
					return true;
				}
			}
		]);

		handleShortcutKeydown(makeKeyEvent({ key: 'c', defaultPrevented: true }).event);
		handleShortcutKeydown(makeKeyEvent({ key: 'c', isComposing: true }).event);
		expect(fired).toBe(0);
		// In Node there is no Element — the dialog guard degrades to "not in a
		// dialog" and the plain-object target never matches a real dialog.
		expect(isTypingTarget({ tagName: 'DIV' } as unknown as EventTarget)).toBe(false);
		unregister();
	});

	it('prefers route scope over global for the same key', () => {
		const fired: string[] = [];
		const unGlobal = registerGlobalShortcuts([
			{
				id: 'g.search',
				keys: 'Mod+K',
				label: 'Global search',
				group: 'general',
				handler: () => {
					fired.push('global');
					return true;
				}
			}
		]);
		const unRoute = registerRouteShortcuts([
			{
				id: 't.search',
				keys: 'Mod+K',
				label: 'List search',
				group: 'list',
				handler: () => {
					fired.push('route');
					return true;
				}
			}
		]);

		handleShortcutKeydown(makeKeyEvent({ key: 'k', ctrlKey: true }).event);
		expect(fired).toEqual(['route']);

		unRoute();
		unGlobal();
	});

	it('does not consume the key when the handler reports no action', () => {
		const unregister = registerRouteShortcuts([
			{ id: 't.search', keys: 'Mod+K', label: 'Search', group: 'list', handler: () => false }
		]);

		const { event, prevented } = makeKeyEvent({ key: 'k', ctrlKey: true });
		handleShortcutKeydown(event);
		expect(prevented()).toBe(0);

		unregister();
	});

	it('matches named keys exactly and not in shifted form', () => {
		let fired = 0;
		const unregister = registerRouteShortcuts([
			{
				id: 't.clear',
				keys: 'Escape',
				label: 'Clear',
				group: 'list',
				handler: () => {
					fired += 1;
					return true;
				}
			}
		]);

		handleShortcutKeydown(makeKeyEvent({ key: 'Escape' }).event);
		expect(fired).toBe(1);

		// Shift+Escape keeps its (rare) native semantics.
		handleShortcutKeydown(makeKeyEvent({ key: 'Escape', shiftKey: true }).event);
		expect(fired).toBe(1);

		unregister();
	});
});

describe('help-open store', () => {
	it('defaults to closed and round-trips', () => {
		expect(getShortcutsHelpOpen()).toBe(false);
		setShortcutsHelpOpen(true);
		expect(getShortcutsHelpOpen()).toBe(true);
		setShortcutsHelpOpen(false);
		expect(getShortcutsHelpOpen()).toBe(false);
	});
});
