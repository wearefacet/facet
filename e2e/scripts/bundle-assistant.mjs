// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import esbuild from 'esbuild';
import esbuildSvelte from 'esbuild-svelte';
import { createRequire } from 'node:module';
import path from 'node:path';

/**
 * Bundles @facetapp/chat into one browser-ready ESM for the miniapp
 * fixture (the app-head-to-toe scenario). The package's vite lib build
 * keeps the runtime dependencies external — a host bundler resolves them —
 * so this script plays that host for the fixture:
 *
 * - `esbuild-svelte` compiles the `.svelte` sources the dependencies ship —
 *   `@lucide/svelte` exposes its icons only as raw Svelte sources under the
 *   "svelte" export condition.
 * - `mermaid` stays external — the optional peer dependency. The bundle
 *   keeps the lazy `import("mermaid")`, whose failure falls back to a plain
 *   code block (the documented host-without-mermaid setup, chat package
 *   README → Mermaid diagrams).
 *
 * Usage: node bundle-assistant.mjs <chat-package-root> <out-file>
 */

const [chatRoot, outfile] = process.argv.slice(2);
if (!chatRoot || !outfile) {
	console.error('usage: node bundle-assistant.mjs <chat-package-root> <out-file>');
	process.exit(2);
}

await esbuild.build({
	entryPoints: [path.resolve(chatRoot, 'dist', 'index.js')],
	outfile,
	bundle: true,
	format: 'esm',
	platform: 'browser',
	target: 'es2022',
	logLevel: 'warning',
	external: ['mermaid'],
	plugins: [
		esbuildSvelte({
			// Component styles must never leak into the host page — the chat
			// package injects its own styles into the shadow root; the same
			// rule keeps any dependency-emitted CSS inside the bundle.
			compilerOptions: { css: 'injected' }
		})
	]
});
