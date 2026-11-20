// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

// @ts-check
import { paraglideVitePlugin } from '@inlang/paraglide-js';
import tailwindcss from '@tailwindcss/vite';
import { defineConfig } from 'vitest/config';
import { playwright } from '@vitest/browser-playwright';
import adapter from '@sveltejs/adapter-node';
import { sveltekit } from '@sveltejs/kit/vite';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { storybookTest } from '@storybook/addon-vitest/vitest-plugin';
import { createLogger } from 'vite';
import type { Connect, Plugin, PreviewServer, ViteDevServer } from 'vite';

// The browser origin of the dev stack is https://facet.localhost:3443 (the
// Caddy vhost proxy, see caddy/Caddyfile). This server only carries the
// SvelteKit app — /Api/* is proxied by Caddy, never by Vite — so a request
// that arrives here with any other Host is the direct-:5173 mistake: the
// page renders (SSR rewrites /Api to the backend in hooks.server.ts) but
// every browser-side API call 404s with SvelteKit's HTML error page. The
// guard refuses such requests with a page that says where to go.
//
// Allowed: the facet.localhost hostname (any port — HTTPS_PORT is env-tunable
// in the Caddyfile).
//
// Skipped under Vitest: prepareVitest sets VITEST in the main process before
// creating its Vite server, and the browser-mode iframe reaches it on
// http://localhost:<port>.
//
// Skipped under Storybook too: @storybook/builder-vite loads this file into
// Storybook's own dev server (port 6006) and merges every field except
// `build`, and @storybook/sveltekit strips only the two SvelteKit plugins —
// so this plugin would answer 421 to the browser's localhost:6006 module
// requests and the preview iframe would never boot. The Storybook CLI sets
// the STORYBOOK env var in its process before it loads this file.
const FACET_HOSTNAME = 'facet.localhost';

const GUARD_PAGE = `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<title>Wrong origin · Facet</title>
<style>
	body { margin: 0; display: grid; place-items: center; min-height: 100vh; background: #f4f6f8; color: #1a1d24; font: 14px/1.5 system-ui, sans-serif; }
	.card { max-width: 480px; margin: 24px; padding: 28px 32px; background: #fff; border: 1px solid #e4e7ec; border-radius: 13px; box-shadow: 0 8px 24px -8px rgba(16, 24, 40, 0.16); }
	h1 { font-size: 17px; margin: 0 0 10px; }
	p { margin: 0 0 10px; color: #5a6473; }
	code { font-family: ui-monospace, monospace; font-size: 12.5px; background: #eef1f4; border-radius: 6px; padding: 2px 6px; }
	a { color: #8c6410; font-weight: 600; }
</style>
</head>
<body>
<div class="card">
	<h1>This is not the Facet origin</h1>
	<p>This dev server does not proxy <code>/Api</code> — opened directly, every API call fails.</p>
	<p>Open <a href="https://facet.localhost:3443">https://facet.localhost:3443</a> instead.</p>
	<p>If the proxy is not running: <code>caddy start --config caddy/Caddyfile</code> (or <code>./scripts/dev</code>).</p>
</div>
</body>
</html>`;

const originGuard: Connect.NextHandleFunction = (req, res, next) => {
	const host = (req.headers.host ?? '').toLowerCase();
	if (host === FACET_HOSTNAME || host.startsWith(`${FACET_HOSTNAME}:`)) {
		next();
		return;
	}
	// 421 Misdirected Request — the same convention Caddy uses for stale hosts.
	res.statusCode = 421;
	res.setHeader('Content-Type', 'text/html; charset=utf-8');
	res.end(GUARD_PAGE);
};

const attachOriginGuard = (server: ViteDevServer | PreviewServer): void => {
	if (process.env.VITEST || process.env.STORYBOOK) return;
	server.middlewares.use(originGuard);
};

const facetOriginGuard: Plugin = {
	name: 'facet-origin-guard',
	// First in the plugin list: the SvelteKit dev middleware fully answers
	// page requests, so a later-registered middleware would never run.
	configureServer: attachOriginGuard,
	configurePreviewServer: attachOriginGuard
};

// scripts/dev sets FACET_HIDE_DEV_URLS=1. The only browser entry is the Caddy
// origin (https://facet.localhost:3443), and scripts/dev shows that URL in its
// summary. The URL lines Vite prints (`➜  Local: http://localhost:5173/`,
// `➜  Network: …`) point at the raw dev server — the direct-visit path the
// origin guard blocks — so a filtered logger drops those lines. A bare
// `pnpm dev` keeps the default banner.
const facetLogger = createLogger();
if (process.env.FACET_HIDE_DEV_URLS === '1') {
	const printInfo = facetLogger.info.bind(facetLogger);
	facetLogger.info = (msg, options) => {
		// printServerUrls bolds "Local"/"Network"; strip the SGR codes first.
		// eslint-disable-next-line no-control-regex -- ESC (\x1b) is the ANSI escape lead; the regex targets it deliberately.
		const plain = msg.replace(/\x1b\[[0-9;]*m/g, '');
		if (/^\s*➜\s+(Local|Network):/.test(plain)) return;
		printInfo(msg, options);
	};
}

const dirname =
	typeof __dirname !== 'undefined' ? __dirname : path.dirname(fileURLToPath(import.meta.url));

// More info at: https://storybook.js.org/docs/next/writing-tests/integrations/vitest-addon
export default defineConfig({
	optimizeDeps: {
		// All CodeMirror packages stay excluded so every copy resolves from the
		// root node_modules (the @codemirror/* sub-packages are declared there —
		// svelte-codemirror-editor imports them without declaring them). Never
		// exclude-experiment here without reading doc/frontend/workflow.md →
		// CodeMirror quirks: partial optimization duplicates instances.
		exclude: [
			'svelte-codemirror-editor',
			'codemirror',
			'@codemirror/lang-markdown',
			'@codemirror/language-data',
			'@codemirror/legacy-modes',
			'@codemirror/language',
			'@codemirror/state',
			'@codemirror/view',
			'@lezer/highlight',
			'@lezer/common'
		]
	},
	resolve: {
		dedupe: ['@lezer/highlight', '@lezer/common', '@codemirror/state', '@codemirror/view']
	},
	customLogger: facetLogger,
	// No `server.proxy` here: in dev the browser talks to the Caddy proxy
	// (https://facet.localhost:3443, see caddy/Caddyfile), which routes /Api/* to
	// the backend and everything else to this dev server. A Vite-level /Api
	// proxy would bypass Caddy and split the app across two origins.
	plugins: [
		facetOriginGuard,
		tailwindcss(),
		sveltekit({
			compilerOptions: {
				// Force runes mode for the project, except for libraries. Can be removed in svelte 6.
				runes: ({ filename }) =>
					filename.split(/[/\\]/).includes('node_modules') ? undefined : true
			},
			// adapter-node produces the self-contained Node server the release
			// container runs (`node build`). See https://svelte.dev/docs/kit/adapter-node.
			adapter: adapter()
		}),
		paraglideVitePlugin({
			project: './project.inlang',
			outdir: './src/lib/paraglide'
		})
	],
	test: {
		expect: {
			requireAssertions: true
		},
		projects: [
			// Pure logic: node environment, no browser. Fast and isolated.
			{
				extends: './vite.config.ts',
				test: {
					name: 'server',
					environment: 'node',
					testTimeout: 1000,
					include: ['src/**/*.{test,spec}.{js,ts}'],
					exclude: ['src/**/*.svelte.{test,spec}.{js,ts}']
				}
			},
			// Components: stories run through @storybook/addon-vitest in the browser.
			// NOTE on isolate: false — vitest's default (isolate: true) creates one
			// iframe per test file and KEEPS every iframe in the orchestrator page for
			// the whole run. Chromium retains the compositor/raster shared-memory
			// segments of each iframe (unlinked /tmp tmpfs files held by the renderer),
			// so 108 files accumulate 10-15+ GB of kernel Shmem and freeze the machine
			// (see tmp/RAM_INVESTIGATION.md). With isolate: false all files share one
			// iframe, which caps Shmem at ~400 MB. Storybook still clears its story
			// canvas between stories, so per-story DOM isolation is preserved; only
			// module-level/window state is shared across files in the same project.
			{
				extends: true,
				plugins: [
					// The plugin will run tests for the stories defined in your Storybook config
					// See options at: https://storybook.js.org/docs/next/writing-tests/integrations/vitest-addon#storybooktest
					storybookTest({
						configDir: path.join(dirname, '.storybook')
					})
				],
				test: {
					name: 'storybook',
					// Bound memory: run one file at a time in a single worker so only
					// one Chromium exists at once (defaults fork per-core).
					// With isolate:false every file shares one long-lived page, so
					// GC/raster stalls occasionally exceed a wait's budget mid-play
					// (observed as rare single-test failures, e.g. a default-1s
					// waitFor after a userEvent sequence). Doubling the per-test
					// budget and retrying once keeps those one-off stalls from
					// failing the suite; a real regression still fails twice.
					// A retry re-runs on the SAME page: the orchestrator keeps one
					// iframe for the whole run and recreates it only after the last
					// file, and there is no page-restart hook between attempts. A
					// crash that corrupts the page must be fixed at the source, not
					// retried — stories keep args read-only (session-local bag
					// clones, see session-bag.ts) and DocumentViewTemplate renders
					// a diagnostic instead of throwing on a missing node.
					fileParallelism: false,
					maxConcurrency: 1,
					maxWorkers: 1,
					browser: {
						enabled: true,
						headless: true,
						provider: playwright({}),
						isolate: false,
						instances: [
							{
								browser: 'chromium'
							}
						]
					},
					testTimeout: 10_000,
					retry: 1
				}
			}
		]
	}
});
