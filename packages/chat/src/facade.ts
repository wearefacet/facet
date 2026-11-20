// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { AssistantDriver } from './driver/AssistantDriver.js';
import { clearAssistantStorage } from './chat/assistantWindowState.js';
import { FacetAssistantElement } from './element/facet-assistant.svelte.js';
import { FacetAssistantWindowElement } from './element/facet-assistant-window.svelte.js';

/**
 * The `FacetAssistant` facade — the one-call entry for host applications.
 *
 * Two mounts share one config and one active chat:
 *
 * - `open(...)` — the floating window (`<facet-assistant-window>`), docked
 *   bottom-right. The first call configures the facade and opens the window;
 *   later calls reuse the same element.
 * - `mount(target, ...)` — the inline panel (`<facet-assistant>`) inside a
 *   host container; the host owns the layout.
 *
 * Activating one mount removes the other, so exactly one chat instance (one
 * driver, one event stream) runs at a time. `close` / `toggle` act on the
 * active mount; `destroy` tears everything down and clears the persisted
 * window state.
 *
 * The facade never sees credentials: the host passes its own authed `fetch`
 * (see the README's Host auth section).
 */

/** Config for `configure` / `open` / `mount`. Every field is optional and
 * later calls merge over the stored config; the fields a host never set
 * fall back to the elements' own defaults. */
export interface FacetAssistantConfig {
	/** Facet origin (+ optional path prefix) for the default HTTP driver. */
	baseUrl?: string;
	/** The host's authed fetch — DPoP proof, bearer, or cookie session. */
	fetch?: typeof fetch;
	/** The Facet app (`app.App`) this assistant is scoped to. The
	 * conversation rail filters on it. */
	appId?: string;
	/** BCP-47 language tag, baked into the backend's `## Language` block. */
	language?: string;
	/** Display name — window header and turn headers. */
	name?: string;
	/** Transport override — swaps the default HTTP driver. */
	driver?: AssistantDriver;
	/** `--facet-*` design-token overrides, set on the mounted elements.
	 * Custom properties inherit into the shadow root. */
	tokens?: Record<string, string>;
	/** Floating mount: show the round launcher bubble in the bottom-right
	 * corner while the window is closed. One click re-opens the window. */
	bubble?: boolean;
}

type WindowElement = FacetAssistantWindowElement;
type InlineElement = FacetAssistantElement;
type ActiveMount = 'window' | 'inline';

let config: FacetAssistantConfig | null = null;
let windowEl: WindowElement | null = null;
let inlineEl: InlineElement | null = null;
let active: ActiveMount | null = null;

function requireConfig(): FacetAssistantConfig {
	if (!config) {
		throw new Error(
			'FacetAssistant is not configured. Call FacetAssistant.configure({ baseUrl, fetch, appId }) first, or pass the config to open() / mount().'
		);
	}
	return config;
}

function assertBrowser(action: string): void {
	if (typeof document === 'undefined') {
		throw new Error(`FacetAssistant.${action} runs in a browser only.`);
	}
}

function applyTokens(el: HTMLElement, tokens: Record<string, string>): void {
	for (const [key, value] of Object.entries(tokens)) {
		// Tokens are CSS custom properties; anything else is a host typo and
		// would leak onto the element's inline style.
		if (!key.startsWith('--')) continue;
		el.style.setProperty(key, value);
	}
}

function applyConfig(el: WindowElement | InlineElement, c: FacetAssistantConfig): void {
	if (c.baseUrl !== undefined) el.baseUrl = c.baseUrl;
	if (c.appId !== undefined) el.appId = c.appId;
	if (c.language !== undefined) el.language = c.language;
	if (c.name !== undefined) el.name = c.name;
	if (c.fetch !== undefined) el.fetch = c.fetch;
	if (c.driver !== undefined) el.driver = c.driver;
	if (c.tokens !== undefined) applyTokens(el, c.tokens);
	if (el instanceof FacetAssistantWindowElement && c.bubble !== undefined) {
		el.bubble = c.bubble;
	}
}

function resolveTarget(target: string | HTMLElement): HTMLElement {
	if (typeof target !== 'string') return target;
	const found = document.querySelector<HTMLElement>(target);
	if (!found) {
		throw new Error(`FacetAssistant.mount: no element matches "${target}".`);
	}
	return found;
}

function ensureWindow(c: FacetAssistantConfig): WindowElement {
	if (windowEl) return windowEl;
	windowEl = document.createElement('facet-assistant-window') as WindowElement;
	applyConfig(windowEl, c);
	document.body.appendChild(windowEl);
	return windowEl;
}

function ensureInline(target: HTMLElement, c: FacetAssistantConfig): InlineElement {
	if (inlineEl) {
		// appendChild moves an already-mounted panel to a new container.
		if (inlineEl.parentElement !== target) target.appendChild(inlineEl);
		return inlineEl;
	}
	inlineEl = document.createElement('facet-assistant') as InlineElement;
	applyConfig(inlineEl, c);
	target.appendChild(inlineEl);
	return inlineEl;
}

function removeWindow(): void {
	if (!windowEl) return;
	windowEl.remove();
	windowEl = null;
}

function removeInline(): void {
	if (!inlineEl) return;
	inlineEl.remove();
	inlineEl = null;
}

function activate(mode: ActiveMount): void {
	if (mode === 'window') removeInline();
	else removeWindow();
	active = mode;
}

export const FacetAssistant = {
	/** Stores the config (merged over any previous one) and applies it to
	 * the live mounts. Mounts nothing. */
	configure(next: FacetAssistantConfig): void {
		config = { ...config, ...next };
		if (windowEl) applyConfig(windowEl, config);
		if (inlineEl) applyConfig(inlineEl, config);
	},

	/** Shows the floating window. The first call configures the facade;
	 * later calls are idempotent — the same window element re-opens. */
	open(next?: FacetAssistantConfig): void {
		if (next) FacetAssistant.configure(next);
		const c = requireConfig();
		assertBrowser('open');
		activate('window');
		ensureWindow(c).open();
	},

	/** Mounts the inline panel into a host container (a selector or an
	 * element) and returns the `<facet-assistant>` element. The host owns
	 * the layout; the panel fills the container. */
	mount(target: string | HTMLElement, next?: FacetAssistantConfig): InlineElement {
		if (next) FacetAssistant.configure(next);
		const c = requireConfig();
		assertBrowser('mount');
		const host = resolveTarget(target);
		activate('inline');
		const el = ensureInline(host, c);
		el.style.display = '';
		return el;
	},

	/** Hides the active mount: closes the window (persisted), or hides the
	 * inline panel. Nothing when no mount is active. */
	close(): void {
		if (active === 'window' && windowEl) windowEl.close();
		else if (active === 'inline' && inlineEl) inlineEl.style.display = 'none';
	},

	/** Flips the visibility of the active mount. Nothing when no mount is
	 * active. */
	toggle(): void {
		if (active === 'window' && windowEl) {
			windowEl.toggle();
		} else if (active === 'inline' && inlineEl) {
			const hidden = inlineEl.style.display === 'none';
			inlineEl.style.display = hidden ? '' : 'none';
		}
	},

	/** Removes every mount, clears the stored config, and clears the
	 * persisted window state (session storage). */
	destroy(): void {
		removeWindow();
		removeInline();
		active = null;
		config = null;
		clearAssistantStorage();
	}
} as const;
