// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { readFileSync } from 'node:fs';
import { afterEach, describe, expect, it, vi } from 'vitest';
import type { Command } from 'commander';
import { createProgram } from '../src/index.js';

const PACKAGE_VERSION = JSON.parse(
	readFileSync(new URL('../package.json', import.meta.url), 'utf8')
).version as string;

vi.mock('../src/commands/init.js', () => ({ runInit: vi.fn() }));
vi.mock('../src/commands/setup-dev.js', () => ({ runSetupDev: vi.fn() }));
vi.mock('../src/commands/connect.js', () => ({ runConnect: vi.fn() }));
vi.mock('../src/commands/apikey.js', () => ({ runApikey: vi.fn() }));
vi.mock('../src/commands/login.js', () => ({ runLogin: vi.fn() }));
vi.mock('../src/commands/logout.js', () => ({ runLogout: vi.fn() }));
vi.mock('../src/commands/whoami.js', () => ({ runWhoami: vi.fn() }));
vi.mock('../src/commands/deploy.js', () => ({ runDeploy: vi.fn() }));
vi.mock('../src/commands/releases.js', () => ({ runReleases: vi.fn() }));
vi.mock('../src/commands/rollback.js', () => ({ runRollback: vi.fn() }));

import { runInit } from '../src/commands/init.js';
import { runSetupDev } from '../src/commands/setup-dev.js';
import { runConnect } from '../src/commands/connect.js';
import { runApikey } from '../src/commands/apikey.js';
import { runLogin } from '../src/commands/login.js';
import { runLogout } from '../src/commands/logout.js';
import { runWhoami } from '../src/commands/whoami.js';
import { runDeploy } from '../src/commands/deploy.js';
import { runReleases } from '../src/commands/releases.js';
import { runRollback } from '../src/commands/rollback.js';

const COMMANDS = [
	'init',
	'setup-dev',
	'connect',
	'apikey',
	'login',
	'logout',
	'whoami',
	'deploy',
	'releases',
	'rollback'
] as const;

function findCommand(program: Command, name: string): Command {
	const command = program.commands.find((candidate) => candidate.name() === name);
	if (!command) throw new Error(`command not found: ${name}`);
	return command;
}

/** Runs one command through commander, the way the binary entry point does. */
async function run(...args: string[]): Promise<void> {
	const program = createProgram();
	const previousArgv = process.argv;
	// Commander reads arguments from index 2, after the node executable
	// and the script path.
	process.argv = ['node', 'facet-cli', ...args];
	try {
		program.parse(process.argv);
		// The action is async; give its error boundary a tick to land.
		await new Promise<void>((resolve) => setTimeout(resolve, 0));
	} finally {
		process.argv = previousArgv;
	}
}

describe('cli program', () => {
	it('registers the ten commands in order', () => {
		const program = createProgram();
		expect(program.commands.map((command) => command.name())).toEqual([...COMMANDS]);
	});

	it('carries the package version', () => {
		expect(createProgram().version()).toBe(PACKAGE_VERSION);
	});

	it('declares the deploy flags', () => {
		const flags = findCommand(createProgram(), 'deploy').options.map((option) => option.flags);
		expect(flags).toContain('--target <name>');
		expect(flags).toContain('--note <text>');
		expect(flags).toContain('--no-activate');
	});

	it('declares the init flags', () => {
		const flags = findCommand(createProgram(), 'init').options.map((option) => option.flags);
		expect(flags).toContain('--yes');
		expect(flags).toContain('--app <slug>');
		expect(flags).toContain('--build <dir>');
		expect(flags).toContain('--server <url>');
	});

	it('declares the setup-dev flags', () => {
		const flags = findCommand(createProgram(), 'setup-dev').options.map((option) => option.flags);
		for (const flag of [
			'--dir <path>',
			'--hostname <name>',
			'--port <n>',
			'--watch <dir>',
			'--no-watch',
			'--no-start',
			'--no-key',
			'--force',
			'--yes'
		]) {
			expect(flags).toContain(flag);
		}
	});

	it('expects a required revision argument on rollback', () => {
		const [revisionArg] = findCommand(createProgram(), 'rollback')._args;
		expect(revisionArg?.required).toBe(true);
	});

	it('exposes the --target flag on the instance commands', () => {
		for (const name of [
			'connect',
			'apikey',
			'login',
			'logout',
			'whoami',
			'releases',
			'rollback'
		] as const) {
			const flags = findCommand(createProgram(), name).options.map((option) => option.flags);
			expect(flags).toContain('--target <name>');
		}
	});

	describe('wired actions', () => {
		afterEach(() => {
			vi.restoreAllMocks();
			process.exitCode = undefined;
			vi.clearAllMocks();
		});

		it('routes init to its runner', async () => {
			await run('init');
			expect(runInit).toHaveBeenCalledWith(process.cwd(), {});
		});

		it('routes the init flags to its runner', async () => {
			await run(
				'init',
				'--yes',
				'--app',
				'slug',
				'--build',
				'dist',
				'--server',
				'https://facet.localhost:3443'
			);
			expect(runInit).toHaveBeenCalledWith(process.cwd(), {
				yes: true,
				app: 'slug',
				build: 'dist',
				server: 'https://facet.localhost:3443'
			});
		});

		it('routes the deploy flags to its runner', async () => {
			await run('deploy', '--target', 'staging', '--note', 'fix nav', '--no-activate');
			expect(runDeploy).toHaveBeenCalledWith(process.cwd(), {
				target: 'staging',
				note: 'fix nav',
				activate: false
			});
		});

		it('defaults deploy to activate', async () => {
			await run('deploy');
			expect(runDeploy).toHaveBeenCalledWith(process.cwd(), { activate: true });
		});

		it('routes the rollback revision argument', async () => {
			await run('rollback', '2', '--target', 'prod');
			expect(runRollback).toHaveBeenCalledWith(process.cwd(), '2', 'prod');
		});

		it('routes releases to its runner', async () => {
			await run('releases');
			expect(runReleases).toHaveBeenCalledWith(process.cwd(), undefined);
		});

		it('routes login and logout to their runners', async () => {
			await run('login', '--target', 'staging');
			await run('logout');
			await run('whoami');
			expect(runLogin).toHaveBeenCalledWith(process.cwd(), 'staging');
			expect(runLogout).toHaveBeenCalledWith(process.cwd(), undefined);
			expect(runWhoami).toHaveBeenCalledWith(process.cwd(), undefined);
		});

		it('routes connect and apikey to their runners', async () => {
			await run('connect', '--target', 'prod');
			await run('apikey');
			expect(runConnect).toHaveBeenCalledWith(process.cwd(), 'prod', { role: undefined });
			expect(runApikey).toHaveBeenCalledWith(process.cwd(), undefined);
		});

		it('routes the connect --role flag to its runner', async () => {
			await run('connect', '--target', 'prod', '--role', 'warehouse');
			expect(runConnect).toHaveBeenCalledWith(process.cwd(), 'prod', { role: 'warehouse' });
		});

		it('routes setup-dev and its flags to its runner', async () => {
			await run('setup-dev', '--dir', '/tmp/x', '--port', '3444', '--no-watch', '--no-start');
			expect(runSetupDev).toHaveBeenCalledWith({
				dir: '/tmp/x',
				hostname: undefined,
				port: 3444,
				watch: false,
				noStart: true,
				noKey: false,
				force: undefined,
				yes: undefined
			});
		});

		it('defaults setup-dev to start and key', async () => {
			await run('setup-dev', '--yes');
			expect(runSetupDev).toHaveBeenCalledWith({
				dir: undefined,
				hostname: undefined,
				port: undefined,
				watch: undefined,
				noStart: false,
				noKey: false,
				force: undefined,
				yes: true
			});
		});

		it('prints command failures to stderr and fails the run', async () => {
			const errors: unknown[] = [];
			vi.spyOn(console, 'error').mockImplementation((message) => errors.push(message));
			vi.mocked(runWhoami).mockRejectedValueOnce(new Error('no session'));

			await run('whoami');

			expect(errors).toHaveLength(1);
			expect(String(errors[0])).toContain('error: no session');
			expect(process.exitCode).toBe(1);
		});
	});
});
