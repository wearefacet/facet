// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { defineConfig } from 'vite';
import { svelte } from '@sveltejs/vite-plugin-svelte';

/**
 * Library build: one ESM bundle per public entry. Runtime dependencies stay
 * external — `svelte` is a peer the host resolves, `mermaid` an optional peer
 * the host opts into (its absence falls back to plain code blocks), the rest
 * are plain dependencies the host's bundler resolves.
 */
export default defineConfig({
	plugins: [svelte()],
	build: {
		lib: {
			entry: 'src/index.ts',
			formats: ['es'],
			fileName: 'index'
		},
		rollupOptions: {
			external: [
				/^svelte(\/|$)/,
				/^mermaid($|\/)/,
				/^marked($|\/)/,
				/^highlight\.js(\/|$)/,
				/^@lucide\/svelte($|\/)/
			]
		},
		sourcemap: true
	}
});
