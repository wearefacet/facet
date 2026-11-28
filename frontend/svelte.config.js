// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

// @ts-check
import adapter from '@sveltejs/adapter-node';

/**
 * The project-wide Svelte / SvelteKit config.
 *
 * It lives here rather than inline in `vite.config.ts` because
 * `@sveltejs/vite-plugin-svelte` loads `svelte.config.js` itself — for the app
 * build and for the Storybook dev server alike — and logs
 * "no Svelte config found … using default configuration" when the file is
 * absent. The inline `sveltekit({ … })` options in `vite.config.ts` merge on
 * top of this file, so the runes opt-in and the Node adapter stay declared
 * once, here.
 */
const config = {
	compilerOptions: {
		// Force runes mode for the project, except for libraries. Can be removed in svelte 6.
		runes: ({ filename }) => (filename.split(/[/\\]/).includes('node_modules') ? undefined : true)
	},
	kit: {
		// adapter-node produces the self-contained Node server the release
		// container runs (`node build`). See https://svelte.dev/docs/kit/adapter-node.
		adapter: adapter()
	}
};

export default config;
