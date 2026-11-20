// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import shadowCss from '../styles/shadow.css?inline';

/**
 * Injects the shadow-root sheet (design tokens + the inner reset) into an
 * element's shadow root. Component styles arrive separately — Svelte
 * attaches them to the shadow root at render time (`getRootNode()`-based).
 *
 * Guarded by an id check so a disconnect/reconnect cycle never appends the
 * sheet twice.
 */
export function injectShadowStyles(root: ShadowRoot): void {
	if (root.querySelector('style[data-facet-shadow]')) return;
	const style = document.createElement('style');
	style.setAttribute('data-facet-shadow', '');
	style.textContent = shadowCss;
	root.appendChild(style);
}
