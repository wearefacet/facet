// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { mount, unmount } from 'svelte';
import ChatMount from './ChatMount.svelte';
import { injectShadowStyles } from './shadow-styles.js';
import { readAssistantOpen, writeAssistantOpen } from '../chat/assistantWindowState.js';
import type { AssistantDriver } from '../driver/AssistantDriver.js';

/**
 * `<facet-assistant-window>` — the floating mount.
 *
 * Renders the assistant as a draggable, collapsible, resizable window
 * docked bottom-right, on the same chat core as the inline element. The
 * open state persists under the package-owned key
 * `facet.assistant.app.open` and defaults to open: a host that mounts the
 * element explicitly asked for the assistant.
 *
 * ```js
 * import '@facetapp/chat';
 * const el = document.querySelector('facet-assistant-window');
 * el.baseUrl = 'https://facet.company.tld';
 * el.fetch = hostFetch;
 * el.appId = 'core.app_123';
 * el.close();    // persists facet.assistant.app.open = 'false'
 * el.open();
 * el.toggle();
 * ```
 *
 * With `bubble` set (property or attribute), a round launcher button shows
 * in the bottom-right corner while the window is closed; one click opens
 * the window again.
 *
 * The public surface is data + callbacks only. `fetch` and `driver` are
 * property-only; `baseUrl`, `app-id`, `language` and `name` are also
 * readable as attributes at connect time.
 */
export class FacetAssistantWindowElement extends HTMLElement {
	/** Scalar config — reactive through the $state proxy. */
	#meta = $state<{ baseUrl: string; appId: string; language?: string; name?: string }>({
		baseUrl: '',
		appId: ''
	});
	/** Raw holders so the driver / fetch objects are never wrapped in a
	 * reactive proxy (a proxy would break the driver's private fields). */
	#driver = $state.raw<AssistantDriver | undefined>(undefined);
	#fetchImpl = $state.raw<typeof fetch | undefined>(undefined);

	/** Bubble mode — render the round launcher while the window is closed. */
	#bubble = $state.raw<boolean>(false);

	/** Open state of the window — read from the package-owned storage key,
	 * written back on every change through `open()` / `close()` / `toggle()`. */
	#open = $state.raw<boolean>(readAssistantOpen());

	#app: ReturnType<typeof mount> | null = null;

	static get observedAttributes(): string[] {
		return ['base-url', 'app-id', 'language', 'name', 'bubble'];
	}

	connectedCallback(): void {
		// Adopt values assigned before the element upgraded (see the inline
		// element — same upgrade pattern).
		for (const key of [
			'baseUrl',
			'appId',
			'language',
			'name',
			'bubble',
			'fetch',
			'driver'
		] as const) {
			if (Object.prototype.hasOwnProperty.call(this, key)) {
				const value = (this as unknown as Record<string, unknown>)[key];
				delete (this as unknown as Record<string, never>)[key];
				(this as unknown as Record<string, unknown>)[key] = value;
			}
		}
		const attr = (name: string) => this.getAttribute(name) ?? undefined;
		if (!this.#meta.baseUrl) this.#meta.baseUrl = attr('base-url') ?? '';
		if (!this.#meta.appId) this.#meta.appId = attr('app-id') ?? '';
		if (this.#meta.language === undefined) this.#meta.language = attr('language');
		if (this.#meta.name === undefined) this.#meta.name = attr('name');
		if (!this.#bubble) this.#bubble = this.hasAttribute('bubble');

		if (!this.shadowRoot) this.attachShadow({ mode: 'open' });
		const root = this.shadowRoot!;
		injectShadowStyles(root);

		const host = this;
		this.#app = mount(ChatMount, {
			target: root,
			props: {
				get appId() {
					return host.#meta.appId;
				},
				get baseUrl() {
					return host.#meta.baseUrl;
				},
				get fetch() {
					return host.#fetchImpl;
				},
				get language() {
					return host.#meta.language;
				},
				get name() {
					return host.#meta.name;
				},
				get driver() {
					return host.#driver;
				},
				get floating() {
					return true;
				},
				get open() {
					return host.#open;
				},
				get bubble() {
					return host.#bubble;
				},
				get onclose() {
					return () => host.close();
				},
				get onopen() {
					return () => host.open();
				}
			}
		});
	}

	disconnectedCallback(): void {
		if (this.#app) {
			void unmount(this.#app);
			this.#app = null;
		}
	}

	attributeChangedCallback(name: string, _old: string | null, value: string | null): void {
		if (name === 'bubble') {
			this.#bubble = value !== null;
			return;
		}
		if (value === null) return;
		if (name === 'base-url') this.#meta.baseUrl = value;
		else if (name === 'app-id') this.#meta.appId = value;
		else if (name === 'language') this.#meta.language = value;
		else if (name === 'name') this.#meta.name = value;
	}

	/** Facet origin (+ optional path prefix) for the default HTTP driver. */
	get baseUrl(): string {
		return this.#meta.baseUrl;
	}
	set baseUrl(value: string) {
		this.#meta.baseUrl = value;
	}

	/** The Facet app this assistant is scoped to. */
	get appId(): string {
		return this.#meta.appId;
	}
	set appId(value: string) {
		this.#meta.appId = value;
	}

	/** BCP-47 language tag for the backend's `## Language` block. */
	get language(): string | undefined {
		return this.#meta.language;
	}
	set language(value: string | undefined) {
		this.#meta.language = value;
	}

	/** The configured assistant name. */
	get name(): string | undefined {
		return this.#meta.name;
	}
	set name(value: string | undefined) {
		this.#meta.name = value;
	}

	/** The host's authed fetch. The package never sees credentials. */
	get fetch(): typeof fetch | undefined {
		return this.#fetchImpl;
	}
	set fetch(value: typeof fetch | undefined) {
		this.#fetchImpl = value;
	}

	/** Transport override — swaps the default HTTP driver. */
	get driver(): AssistantDriver | undefined {
		return this.#driver;
	}
	set driver(value: AssistantDriver | undefined) {
		this.#driver = value;
	}

	/** Bubble mode — a round launcher shows in the bottom-right corner while
	 * the window is closed; one click re-opens the window. */
	get bubble(): boolean {
		return this.#bubble;
	}
	set bubble(value: boolean) {
		this.#bubble = value;
	}

	/** Whether the window is currently open. */
	get isOpen(): boolean {
		return this.#open;
	}

	/** Opens the window and persists the state. */
	open(): void {
		this.#open = true;
		writeAssistantOpen(true);
	}

	/** Closes the window and persists the state. */
	close(): void {
		this.#open = false;
		writeAssistantOpen(false);
	}

	/** Flips the open state and persists it. */
	toggle(): void {
		if (this.#open) this.close();
		else this.open();
	}
}

if (typeof window !== 'undefined' && !customElements.get('facet-assistant-window')) {
	customElements.define('facet-assistant-window', FacetAssistantWindowElement);
}
