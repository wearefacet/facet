// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
	FacetAssistant,
	FacetAssistantElement,
	FacetAssistantWindowElement,
	createMockAssistant,
	MOCK_APP_ID
} from '../src/index.js';
import { clearAssistantStorage } from '../src/chat/assistantWindowState.js';

/**
 * Unit tests for the `FacetAssistant` facade. The mock driver stands in
 * for the backend, so the mounts run their real wiring with no network.
 * Covers the Phase 5 test set: idempotent open, mount + destroy cleanup,
 * bubble mount, toggle targets the active mount.
 */

const CONFIG = {
	baseUrl: 'https://facet.company.tld',
	appId: MOCK_APP_ID,
	driver: createMockAssistant()
};

beforeEach(() => {
	FacetAssistant.destroy();
	document.body.innerHTML = '';
	clearAssistantStorage();
});

async function windowElement(): Promise<FacetAssistantWindowElement> {
	const el = document.querySelector('facet-assistant-window') as FacetAssistantWindowElement;
	expect(el).toBeTruthy();
	await vi.waitFor(() => {
		expect(el.shadowRoot?.querySelector('.chat-panel')).toBeTruthy();
	});
	return el;
}

describe('FacetAssistant.open — floating window', () => {
	it('configures on the first call and opens the window', async () => {
		FacetAssistant.open(CONFIG);
		const el = await windowElement();
		expect(el.isOpen).toBe(true);
		expect(el.baseUrl).toBe(CONFIG.baseUrl);
		expect(el.appId).toBe(MOCK_APP_ID);
	});

	it('is idempotent — a second call re-uses the same element', async () => {
		FacetAssistant.open(CONFIG);
		FacetAssistant.open();
		expect(document.querySelectorAll('facet-assistant-window')).toHaveLength(1);

		FacetAssistant.close();
		FacetAssistant.open();
		// Still one element, and it is open again.
		expect(document.querySelectorAll('facet-assistant-window')).toHaveLength(1);
		const el = await windowElement();
		expect(el.isOpen).toBe(true);
	});

	it('throws a clear error before any config was given', () => {
		expect(() => FacetAssistant.open()).toThrow(/not configured/);
		expect(document.querySelector('facet-assistant-window')).toBeNull();
	});

	it('applies token overrides to the window element', async () => {
		FacetAssistant.open({ ...CONFIG, tokens: { '--facet-accent': '#008f79' } });
		const el = await windowElement();
		expect(el.style.getPropertyValue('--facet-accent')).toBe('#008f79');
	});
});

describe('FacetAssistant.mount — inline panel', () => {
	it('mounts the panel into the host container and returns the element', async () => {
		const root = document.createElement('div');
		root.id = 'chat-root';
		document.body.appendChild(root);

		const el = FacetAssistant.mount('#chat-root', CONFIG);
		expect(el).toBeInstanceOf(FacetAssistantElement);
		expect(root.contains(el)).toBe(true);

		await vi.waitFor(() => {
			expect(el.shadowRoot?.querySelector('.chat-panel')).toBeTruthy();
		});
	});

	it('throws when the selector matches nothing', () => {
		expect(() => FacetAssistant.mount('#missing-root', CONFIG)).toThrow(/no element matches/);
	});

	it('moving to a new container keeps the same element', async () => {
		const rootA = document.createElement('div');
		rootA.id = 'root-a';
		const rootB = document.createElement('div');
		rootB.id = 'root-b';
		document.body.append(rootA, rootB);

		const el = FacetAssistant.mount('#root-a', CONFIG);
		FacetAssistant.mount('#root-b');
		expect(rootA.querySelector('facet-assistant')).toBeNull();
		expect(rootB.contains(el)).toBe(true);
		expect(document.querySelectorAll('facet-assistant')).toHaveLength(1);
	});
});

describe('FacetAssistant.close / toggle — the active mount', () => {
	it('toggle targets the active mount — window first, then inline', async () => {
		const root = document.createElement('div');
		root.id = 'chat-root';
		document.body.appendChild(root);

		FacetAssistant.open(CONFIG);
		const win = await windowElement();

		// Active mount: window. Toggle hides it (and persists).
		FacetAssistant.toggle();
		expect(win.isOpen).toBe(false);
		expect(window.sessionStorage.getItem('facet.assistant.app.open')).toBe('false');
		await vi.waitFor(() => {
			expect(win.shadowRoot?.querySelector('.assistant-window')).toBeNull();
		});

		// Mounting inline activates the inline mount and removes the window.
		const inline = FacetAssistant.mount('#chat-root');
		expect(document.querySelectorAll('facet-assistant-window')).toHaveLength(0);
		await vi.waitFor(() => {
			expect(inline.shadowRoot?.querySelector('.chat-panel')).toBeTruthy();
		});

		// Active mount: inline. Toggle flips its visibility only.
		FacetAssistant.toggle();
		expect(inline.style.display).toBe('none');
		FacetAssistant.toggle();
		expect(inline.style.display).toBe('');
	});

	it('close hides the inline panel; open re-activates the window', async () => {
		const root = document.createElement('div');
		root.id = 'chat-root';
		document.body.appendChild(root);

		const inline = FacetAssistant.mount('#chat-root', CONFIG);
		FacetAssistant.close();
		expect(inline.style.display).toBe('none');

		FacetAssistant.open();
		// The inline mount is gone; the floating window is back.
		expect(inline.isConnected).toBe(false);
		const win = await windowElement();
		expect(win.isOpen).toBe(true);
	});

	it('close and toggle do nothing when no mount is active', () => {
		FacetAssistant.configure(CONFIG);
		expect(() => FacetAssistant.close()).not.toThrow();
		expect(() => FacetAssistant.toggle()).not.toThrow();
	});
});

describe('FacetAssistant — bubble option', () => {
	it('shows the launcher while the window is closed; a click re-opens it', async () => {
		FacetAssistant.open({ ...CONFIG, bubble: true });
		const el = await windowElement();
		expect(el.bubble).toBe(true);

		FacetAssistant.close();
		await vi.waitFor(() => {
			expect(el.shadowRoot?.querySelector('.assistant-window')).toBeNull();
		});

		const launcher = el.shadowRoot?.querySelector<HTMLButtonElement>('.launcher');
		expect(launcher).toBeTruthy();

		launcher!.click();
		await vi.waitFor(() => {
			expect(el.shadowRoot?.querySelector('.assistant-window')).toBeTruthy();
		});
		expect(el.isOpen).toBe(true);
		// The launcher is gone while the window is open.
		expect(el.shadowRoot?.querySelector('.launcher')).toBeNull();
	});

	it('a mid-flight bubble flip applies through configure', async () => {
		FacetAssistant.open(CONFIG);
		const el = await windowElement();

		FacetAssistant.configure({ bubble: true });
		expect(el.bubble).toBe(true);

		FacetAssistant.close();
		await vi.waitFor(() => {
			expect(el.shadowRoot?.querySelector('.launcher')).toBeTruthy();
		});

		FacetAssistant.configure({ bubble: false });
		expect(el.bubble).toBe(false);
		await vi.waitFor(() => {
			expect(el.shadowRoot?.querySelector('.launcher')).toBeNull();
		});
	});
});

describe('FacetAssistant.destroy — cleanup', () => {
	it('removes every mount and clears the stored config', async () => {
		const root = document.createElement('div');
		root.id = 'chat-root';
		document.body.appendChild(root);

		FacetAssistant.open(CONFIG);
		FacetAssistant.mount('#chat-root');

		FacetAssistant.destroy();

		expect(document.querySelector('facet-assistant')).toBeNull();
		expect(document.querySelector('facet-assistant-window')).toBeNull();

		// The config is gone — open() needs a fresh configure.
		expect(() => FacetAssistant.open()).toThrow(/not configured/);
	});

	it('clears the persisted window state', () => {
		FacetAssistant.open(CONFIG);
		FacetAssistant.close();
		expect(window.sessionStorage.getItem('facet.assistant.app.open')).toBe('false');

		FacetAssistant.destroy();
		expect(window.sessionStorage.getItem('facet.assistant.app.open')).toBeNull();
	});

	it('is safe to call twice', () => {
		FacetAssistant.open(CONFIG);
		FacetAssistant.destroy();
		expect(() => FacetAssistant.destroy()).not.toThrow();
	});
});
