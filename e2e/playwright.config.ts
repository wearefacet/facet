// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import {
	defineConfig,
	type PlaywrightTestConfig,
	type PlaywrightTestOptions,
	type PlaywrightWorkerOptions
} from '@playwright/test';
import { existsSync, readdirSync, readFileSync } from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));

/** storageState written by the `setup` project (fresh per stack). */
const authFile = path.join(here, '.auth', 'admin.json');

const artifactsDir = path.join(here, 'artifacts');

/**
 * Scenario project names from `scenarios.txt` — the same list
 * `run-suite.sh` iterates when it boots one stack per scenario.
 */
function readScenarioNames() {
	return readFileSync(path.join(here, 'scenarios.txt'), 'utf8')
		.split('\n')
		.map((line) => line.trim())
		.filter((line) => line.length > 0 && !line.startsWith('#'));
}

/** The scenario files that exist right now (top level of `tests/`). */
function readScenarioFiles() {
	const testsDir = path.join(here, 'tests');
	if (!existsSync(testsDir)) return [];
	return readdirSync(testsDir).filter((file) => file.endsWith('.e2e.ts'));
}

const scenarioNames = readScenarioNames();
const scenarioFiles = readScenarioFiles();

/**
 * Guard: `testMatch` binds files to projects silently. A new
 * scenario file with no matching project would never run. Fail the run
 * when a `tests/*.e2e.ts` file matches no project in `scenarios.txt`.
 */
const uncovered = scenarioFiles.filter((file) => !scenarioNames.includes(file.slice(0, -'.e2e.ts'.length)));
if (uncovered.length > 0) {
	throw new Error(
		`Scenario files with no matching project in scenarios.txt: ${uncovered.join(', ')}. ` +
			'Add a `<name>.e2e.ts` line to scenarios.txt (or rename the file).'
	);
}

/**
 * The browser resolves `*.localhost` (any label depth) to loopback per RFC
 * 6761, but the stack's Caddy is a sibling container — nothing listens on
 * the runner's loopback :3443. The resolver rules point the two vhosts
 * (plus the unknown-host probe `cold.apps.localhost`, never claimed by any
 * app) at Caddy's service name; the Caddy network aliases serve every
 * non-browser client. TLS, Caddy and the auth hook stay on every request
 * path.
 */
const hostResolverRules =
	'MAP facet.localhost caddy, MAP app.apps.localhost caddy, MAP cold.apps.localhost caddy';

const sharedUse: Partial<PlaywrightTestOptions & PlaywrightWorkerOptions> = {
	baseURL: 'https://facet.localhost:3443',
	ignoreHTTPSErrors: true,
	// Bounded actions: every click/fill/goto fails within 10 s; no test
	// retry — a stuck step must abort, not hang the file. expect() shares the same
	// budget via `expect.timeout`; slow-by-design spots (the OAuth callback,
	// one CLI invocation) carry their own explicit, larger timeouts.
	actionTimeout: 10_000,
	navigationTimeout: 10_000,
	launchOptions: {
		args: [`--host-resolver-rules=${hostResolverRules}`]
	},
	// Runs are rare and slow — capture everything (`e2e/README.md`).
	trace: { mode: 'on', screenshots: true, snapshots: true },
	video: 'on',
	screenshot: 'only-on-failure'
};

const config: PlaywrightTestConfig = defineConfig({
	testDir: path.join(here, 'tests'),
	fullyParallel: false,
	workers: 1,
	retries: 0,
	// One scenario file is one `test()` of `test.step()` blocks that must
	// all pass on one stack — give the file its whole lifetime.
	timeout: 5 * 60_000,
	expect: { timeout: 10_000 },
	outputDir: path.join(artifactsDir, 'test-results'),
	reporter: [
		['list'],
		['html', { outputFolder: path.join(artifactsDir, 'report'), open: 'never' }]
	],
	projects: [
		{
			name: 'setup',
			testMatch: /setup\/.*\.setup\.ts/,
			use: sharedUse
		},
		...scenarioNames.map((name) => ({
			name,
			testMatch: new RegExp(`${name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\.e2e\\.ts$`),
			dependencies: ['setup'],
			use: {
				...sharedUse,
				storageState: authFile,
				// Only the served mini-app fixture keys its surface on
				// `data-test`; the product UI keeps the `data-testid`
				// default (e.g. the comment composer).
				...(name === 'app-head-to-toe' ? { testIdAttribute: 'data-test' } : {})
			}
		}))
	]
});

export default config;
