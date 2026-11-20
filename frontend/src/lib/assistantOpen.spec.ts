// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import {
	getAssistantOpen,
	initAssistantOpen,
	setAssistantOpen,
	toggleAssistantOpen
} from './assistantOpen.svelte';

/**
 * Unit tests for the assistant open store. These run in Node (no `window`),
 * which exercises the SSR-safe branches: `initAssistantOpen` is a no-op and
 * `setAssistantOpen` skips the sessionStorage write. The browser branches
 * run against a stubbed `window.sessionStorage`.
 */

/** Map-backed sessionStorage stub — records the last write per key. */
function stubSessionStorage(initial: Record<string, string> = {}) {
	const store = new Map(Object.entries(initial));
	const storage = {
		getItem: (key: string) => (store.has(key) ? store.get(key)! : null),
		setItem: (key: string, value: string) => store.set(key, value),
		removeItem: (key: string) => store.delete(key)
	};
	vi.stubGlobal('window', { sessionStorage: storage });
	return storage;
}

beforeEach(() => {
	// Reset the module flag: init against a closed storage is the SSR default.
	stubSessionStorage();
	initAssistantOpen();
});

afterEach(() => {
	vi.unstubAllGlobals();
});

describe('initAssistantOpen', () => {
	it('defaults to closed without storage', () => {
		// The beforeEach stub is already installed; drop it to simulate SSR.
		vi.unstubAllGlobals();
		initAssistantOpen();

		expect(getAssistantOpen()).toBe(false);
	});

	it('hydrates the persisted open state', () => {
		stubSessionStorage({ 'facet.assistant.open': 'true' });
		initAssistantOpen();

		expect(getAssistantOpen()).toBe(true);
	});

	it('keeps closed for any value other than "true"', () => {
		stubSessionStorage({ 'facet.assistant.open': 'false' });
		initAssistantOpen();
		expect(getAssistantOpen()).toBe(false);

		stubSessionStorage({});
		initAssistantOpen();
		expect(getAssistantOpen()).toBe(false);
	});

	it('stays closed when storage access throws', () => {
		vi.stubGlobal('window', {
			sessionStorage: {
				getItem: () => {
					throw new Error('blocked');
				},
				setItem: () => {}
			}
		});

		expect(() => initAssistantOpen()).not.toThrow();
		expect(getAssistantOpen()).toBe(false);
	});
});

describe('setAssistantOpen', () => {
	it('persists the value as "true" / "false"', () => {
		const storage = stubSessionStorage();

		setAssistantOpen(true);
		expect(getAssistantOpen()).toBe(true);
		expect(storage.getItem('facet.assistant.open')).toBe('true');

		setAssistantOpen(false);
		expect(getAssistantOpen()).toBe(false);
		expect(storage.getItem('facet.assistant.open')).toBe('false');
	});

	it('keeps the in-memory state when the storage write throws', () => {
		vi.stubGlobal('window', {
			sessionStorage: {
				getItem: () => null,
				setItem: () => {
					throw new Error('blocked');
				}
			}
		});

		expect(() => setAssistantOpen(true)).not.toThrow();
		expect(getAssistantOpen()).toBe(true);
	});

	it('skips the write on the server', () => {
		vi.unstubAllGlobals();

		setAssistantOpen(true);

		expect(getAssistantOpen()).toBe(true);
	});
});

describe('toggleAssistantOpen', () => {
	it('flips the state and persists it', () => {
		const storage = stubSessionStorage();

		toggleAssistantOpen();
		expect(getAssistantOpen()).toBe(true);

		toggleAssistantOpen();
		expect(getAssistantOpen()).toBe(false);
		expect(storage.getItem('facet.assistant.open')).toBe('false');
	});
});
