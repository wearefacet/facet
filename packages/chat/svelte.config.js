// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { vitePreprocess } from '@sveltejs/vite-plugin-svelte';

/**
 * Library config. CSS stays `injected` (attached at runtime through
 * `getRootNode()`, so every component style lands inside the host shadow
 * root — none of it may leak into the host page's stylesheets).
 */
export default {
	preprocess: vitePreprocess(),
	compilerOptions: {
		css: 'injected'
	}
};
