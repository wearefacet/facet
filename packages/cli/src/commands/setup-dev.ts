// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import {
	instanceUrl,
	renderCaddyfile,
	renderCompose,
	renderDevConfig,
	renderEnv,
	renderFacetConfig,
	renderGitignore,
	type DevStackInput
} from '../devcompose.js';
import { generateJwtSigningKey, generateSecret } from '../util.js';
import { confirm, confirmDefaultYes, prompt, type PromptFn } from './context.js';

/** Raised when the folder already holds a stack and `--force` is absent. */
export class SetupError extends Error {
	constructor(message: string) {
		super(message);
		this.name = 'SetupError';
	}
}

/** Runs one command and returns its exit code; injectable so tests never spawn. */
export type Runner = (command: string, args: string[], cwd: string) => number;

const defaultRunner: Runner = (command, args, cwd) => {
	const result = spawnSync(command, args, { cwd, stdio: 'inherit' });
	if (result.error !== undefined) {
		throw new SetupError(`Could not run "${command}": ${result.error.message}`);
	}
	return result.status ?? 1;
};

export interface SetupDevOptions {
	promptFn?: PromptFn;
	/** Directory to scaffold; defaults to the current working directory. */
	dir?: string;
	/** Edge hostname; prompted when absent and interactive. */
	hostname?: string;
	/** Edge HTTPS port; prompted when absent and interactive. */
	port?: number;
	/** Watch folder; `false` disables the watcher. */
	watch?: string | false;
	/** Scaffold only — do not start or bootstrap. */
	noStart?: boolean;
	/** Do not run the API-key (connect) step. */
	noKey?: boolean;
	/** Overwrite existing stack files. */
	force?: boolean;
	/** Non-interactive: take every default, never prompt. */
	yes?: boolean;
	/** Test seams. */
	runner?: Runner;
	/** Replaces the connect step; receives the instance URL. */
	connect?: (instanceUrl: string) => Promise<void>;
}

interface Answers {
	hostname: string;
	port: number;
	watchPath?: string;
}

/**
 * Takes an empty folder to a running dev instance: writes the GHCR stack
 * (compose, dev config, `.env`, Caddyfile, `facet.config.json`), initializes
 * git, starts the stack, seeds the known dev admin, and fetches the user's
 * API key. The Facet environment itself is the target — no app deploy is set
 * up, so the generated `facet.config.json` carries targets only.
 */
export async function runSetupDev(options: SetupDevOptions = {}): Promise<void> {
	const root = path.resolve(options.dir ?? process.cwd());
	const ask = options.promptFn ?? prompt;
	const runner = options.runner ?? defaultRunner;

	// ── Pre-flight ───────────────────────────────────────────────────────
	requireDocker(runner, root);

	const answers = await resolveAnswers(options, ask);
	const input: DevStackInput = {
		hostname: answers.hostname,
		port: answers.port,
		version: process.env['FACET_VERSION'] ?? 'latest',
		postgresPassword: generateSecret(),
		jwtSigningKey: generateJwtSigningKey(),
		...(answers.watchPath !== undefined ? { watchPath: '/watch' } : {})
	};

	// ── Write the stack ──────────────────────────────────────────────────
	mkdirSync(root, { recursive: true });
	guardExisting(root, options.force === true);

	writeFileSync(path.join(root, 'compose.yml'), renderCompose(input));
	writeFileSync(path.join(root, '.env'), renderEnv(input), { mode: 0o600 });
	writeFileSync(path.join(root, 'config.dev.yml'), renderDevConfig(input));
	writeFileSync(path.join(root, 'Caddyfile.prod'), renderCaddyfile());
	writeFileSync(path.join(root, 'facet.config.json'), renderFacetConfig(input));
	if (answers.watchPath !== undefined) {
		mkdirSync(path.join(root, 'domains'), { recursive: true });
		writeFileSync(path.join(root, 'domains', '.gitkeep'), '');
	}
	console.log(`Wrote the dev stack in ${root}.`);

	prepareGit(root, runner, options.force === true);

	if (options.noStart === true) {
		console.log('Skipped start (--no-start). Run "docker compose up -d" when ready.');
		return;
	}

	// ── Start + bootstrap ────────────────────────────────────────────────
	console.log('Starting the stack (docker compose up -d --wait)…');
	mustSucceed(runner('docker', ['compose', 'up', '-d', '--wait'], root), 'docker compose up');

	console.log('Seeding the dev admin (db_reset --yes seed:dev)…');
	mustSucceed(
		runner('docker', ['compose', 'run', '--rm', 'backend', 'db_reset', '--yes', 'seed:dev'], root),
		'db_reset seed:dev'
	);

	// ── Report ───────────────────────────────────────────────────────────
	printSummary(input, answers);

	// ── API key ──────────────────────────────────────────────────────────
	if (options.noKey === true) {
		console.log('Skipped the API key. Run "facet-cli connect" to fetch one later.');
		return;
	}
	if (!options.yes && !(await confirm('Fetch an API key now?', ask))) {
		console.log('Skipped the API key. Run "facet-cli connect" to fetch one later.');
		return;
	}
	const url = instanceUrl(input);
	await (options.connect ?? ((u: string) => defaultConnect(root, u)))(url);
}

/** The default connect step: the real `connect` command against the fresh instance. */
async function defaultConnect(root: string, _url: string): Promise<void> {
	const { runConnect } = await import('./connect.js');
	// The generated facet.config.json already targets the instance; connect
	// resolves it through the default target.
	await runConnect(root, undefined, {
		promptFn: async () => 'y'
	});
}

function requireDocker(runner: Runner, cwd: string): void {
	let code: number;
	try {
		code = runner('docker', ['compose', 'version'], cwd);
	} catch (error) {
		throw new SetupError(
			`Docker is required: ${error instanceof Error ? error.message : String(error)}`
		);
	}
	if (code !== 0) {
		throw new SetupError('Docker with Compose is required. Install it and retry.');
	}
}

async function resolveAnswers(options: SetupDevOptions, ask: PromptFn): Promise<Answers> {
	const hostname =
		options.hostname ??
		(options.yes ? 'facet.localhost' : await ask('Hostname', 'facet.localhost'));
	const portAnswer =
		options.port !== undefined
			? String(options.port)
			: options.yes
				? '3443'
				: await ask('HTTPS port', '3443');
	const port = Number.parseInt(portAnswer, 10);
	if (!Number.isInteger(port) || port <= 0 || port > 65535) {
		throw new SetupError(`Invalid port "${portAnswer}". Pass --port <1-65535>.`);
	}

	let watchPath: string | undefined;
	if (options.watch === false) {
		watchPath = undefined;
	} else if (typeof options.watch === 'string') {
		watchPath = options.watch;
	} else if (options.yes) {
		watchPath = 'domains';
	} else if (await confirmDefaultYes('Watch a folder for domain bundles?', ask)) {
		watchPath = (await ask('Watch folder', 'domains')) || 'domains';
	}

	return { hostname, port, watchPath };
}

const STACK_FILES = [
	'compose.yml',
	'.env',
	'config.dev.yml',
	'Caddyfile.prod',
	'facet.config.json'
];

/** Refuses to clobber an existing stack unless `--force`. */
function guardExisting(root: string, force: boolean): void {
	if (force) {
		return;
	}
	const present = STACK_FILES.filter((file) => existsSync(path.join(root, file)));
	if (present.length > 0) {
		throw new SetupError(
			`${root} already holds a dev stack (${present.join(', ')}). ` +
				`Re-run with --force to overwrite, or pick another --dir.`
		);
	}
}

/**
 * `git init` when the folder is not inside a repo, and write `.gitignore`
 * when it is absent. Inside an existing repo, the `.gitignore` is only
 * written when missing, so a host project's file is never clobbered.
 */
function prepareGit(root: string, runner: Runner, force: boolean): void {
	if (!insideGitRepo(root)) {
		const code = runner('git', ['init'], root);
		if (code !== 0) {
			console.warn('warning: git init failed; the folder is not a repository.');
		}
	}
	const gitignore = path.join(root, '.gitignore');
	if (force || !existsSync(gitignore)) {
		writeFileSync(gitignore, renderGitignore());
	}
}

/** Walks up from `root` looking for a `.git` directory. */
function insideGitRepo(root: string): boolean {
	let current = root;
	for (;;) {
		if (existsSync(path.join(current, '.git'))) {
			return true;
		}
		const parent = path.dirname(current);
		if (parent === current) {
			return false;
		}
		current = parent;
	}
}

function mustSucceed(code: number, step: string): void {
	if (code !== 0) {
		throw new SetupError(`${step} failed with exit code ${code}. Check the output above.`);
	}
}

function printSummary(input: DevStackInput, answers: Answers): void {
	const url = instanceUrl(input);
	console.log('');
	console.log('Dev instance is ready.');
	console.log(`  URL:        ${url}`);
	console.log(
		'  Admin:      admin@example.tld / admin  (dev credential — never use in production)'
	);
	console.log(`  Watcher:    ${answers.watchPath === undefined ? 'off' : './domains'}`);
	console.log('  Stop:       docker compose down');
	console.log('  API calls:  Authorization: Bearer $(facet-cli apikey)');
	console.log('');
}
