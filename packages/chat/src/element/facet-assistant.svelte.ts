// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { mount, unmount } from 'svelte';
import ChatMount from './ChatMount.svelte';
import { injectShadowStyles } from './shadow-styles.js';
import type { AssistantDriver } from '../driver/AssistantDriver.js';

/**
 * `<facet-assistant>` — the inline mount.
 *
 * The panel fills whatever container the host gives the element; the host
 * owns the layout, and nothing persists. The public surface is data +
 * callbacks only (no snippet props cross the shadow boundary):
 *
 * ```js
 * import '@facetapp/chat';
 * const el = document.querySelector('facet-assistant');
 * el.baseUrl = 'https://facet.company.tld';
 * el.fetch = hostFetch;      // the host's authed fetch
 * el.appId = 'core.app_123';
 * ```
 *
 * `fetch` and `driver` are property-only; `baseUrl`, `app-id`, `language`
 * and `name` are also readable as attributes at connect time.
 */
export class FacetAssistantElement extends HTMLElement {
	/** Scalar config — reactive through the $state proxy. */
	#meta = $state<{ baseUrl: string; appId: string; language?: string; name?: string }>({
		baseUrl: '',
		appId: ''
	});
	/** Raw holders so the driver / fetch objects are never wrapped in a
	 * reactive proxy (a proxy would break the driver's private fields). */
	#driver = $state.raw<AssistantDriver | undefined>(undefined);
	#fetchImpl = $state.raw<typeof fetch | undefined>(undefined);

	#app: ReturnType<typeof mount> | null = null;

	static get observedAttributes(): string[] {
		return ['base-url', 'app-id', 'language', 'name'];
	}

	constructor() {
		super();
	}

	connectedCallback(): void {
		// Adopt values assigned before the element upgraded (the host may set
		// properties straight after `createElement`, before the definition
		// loads). Own properties shadow the accessors below until dropped.
		for (const key of ['baseUrl', 'appId', 'language', 'name', 'fetch', 'driver'] as const) {
			if (Object.prototype.hasOwnProperty.call(this, key)) {
				const value = (this as unknown as Record<string, unknown>)[key];
				delete (this as unknown as Record<string, never>)[key];
				(this as unknown as Record<string, unknown>)[key] = value;
			}
		}
		// Attribute fallbacks (static markup hosts).
		const attr = (name: string) => this.getAttribute(name) ?? undefined;
		if (!this.#meta.baseUrl) this.#meta.baseUrl = attr('base-url') ?? '';
		if (!this.#meta.appId) this.#meta.appId = attr('app-id') ?? '';
		if (this.#meta.language === undefined) this.#meta.language = attr('language');
		if (this.#meta.name === undefined) this.#meta.name = attr('name');

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
					return false;
				},
				get open() {
					return true;
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
}

if (typeof window !== 'undefined' && !customElements.get('facet-assistant')) {
	customElements.define('facet-assistant', FacetAssistantElement);
}
