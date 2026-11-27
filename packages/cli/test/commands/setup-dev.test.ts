// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, statSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { runSetupDev, type Runner } from '../../src/commands/setup-dev.js';

let root: string;
const logs: string[] = [];

/** Records every command and returns a configurable exit code per command. */
function fakeRunner(exit: number | ((cmd: string, args: string[]) => number) = 0): {
	runner: Runner;
	calls: Array<{ cmd: string; args: string[] }>;
} {
	const calls: Array<{ cmd: string; args: string[] }> = [];
	const runner: Runner = (cmd, args) => {
		calls.push({ cmd, args });
		return typeof exit === 'function' ? exit(cmd, args) : exit;
	};
	return { runner, calls };
}

beforeEach(() => {
	root = mkdtempSync(path.join(os.tmpdir(), 'facet-cli-setup-dev-'));
	logs.length = 0;
	vi.spyOn(console, 'log').mockImplementation((message) => logs.push(message));
	vi.spyOn(console, 'warn').mockImplementation(() => undefined);
});

afterEach(() => {
	rmSync(root, { recursive: true, force: true });
	vi.restoreAllMocks();
});

describe('setup-dev', () => {
	it('writes every stack file', async () => {
		const { runner } = fakeRunner();

		await runSetupDev({ dir: root, runner, noStart: true, noKey: true, yes: true });

		for (const file of [
			'compose.yml',
			'.env',
			'config.dev.yml',
			'Caddyfile.prod',
			'facet.config.json',
			'.gitignore'
		]) {
			expect(existsSync(path.join(root, file))).toBe(true);
		}
	});

	it('writes the env file mode 600', async () => {
		const { runner } = fakeRunner();

		await runSetupDev({ dir: root, runner, noStart: true, noKey: true, yes: true });

		expect(statSync(path.join(root, '.env')).mode & 0o777).toBe(0o600);
	});

	it('generates a facet config with targets only', async () => {
		const { runner } = fakeRunner();

		await runSetupDev({ dir: root, runner, noStart: true, noKey: true, yes: true });

		const config = JSON.parse(readFileSync(path.join(root, 'facet.config.json'), 'utf8'));
		expect(config.app).toBeUndefined();
		expect(config.defaultTarget).toBe('dev');
		expect(config.targets.dev.url).toBe('https://facet.localhost:3443');
	});

	it('honours --hostname and --port', async () => {
		const { runner } = fakeRunner();

		await runSetupDev({
			dir: root,
			runner,
			noStart: true,
			noKey: true,
			yes: true,
			hostname: 'facet.test',
			port: 8443
		});

		const config = JSON.parse(readFileSync(path.join(root, 'facet.config.json'), 'utf8'));
		expect(config.targets.dev.url).toBe('https://facet.test:8443');
	});

	it('creates the domains folder and watch section by default (--yes)', async () => {
		const { runner } = fakeRunner();

		await runSetupDev({ dir: root, runner, noStart: true, noKey: true, yes: true });

		expect(existsSync(path.join(root, 'domains', '.gitkeep'))).toBe(true);
		expect(readFileSync(path.join(root, 'config.dev.yml'), 'utf8')).toContain('domain_watch:');
	});

	it('skips the watcher with watch=false', async () => {
		const { runner } = fakeRunner();

		await runSetupDev({ dir: root, runner, noStart: true, noKey: true, yes: true, watch: false });

		expect(existsSync(path.join(root, 'domains'))).toBe(false);
		expect(readFileSync(path.join(root, 'config.dev.yml'), 'utf8')).not.toContain('domain_watch');
	});

	it('runs git init when the folder is not a repo', async () => {
		const { runner, calls } = fakeRunner();

		await runSetupDev({ dir: root, runner, noStart: true, noKey: true, yes: true });

		expect(calls.some((c) => c.cmd === 'git' && c.args[0] === 'init')).toBe(true);
	});

	it('does not run git init inside an existing repo', async () => {
		const repoRoot = mkdtempSync(path.join(os.tmpdir(), 'facet-cli-repo-'));
		const nested = path.join(repoRoot, 'proj');
		try {
			// A parent .git marks an existing repository.
			mkdirSync(path.join(repoRoot, '.git'), { recursive: true });
			const { runner, calls } = fakeRunner();
			await runSetupDev({ dir: nested, runner, noStart: true, noKey: true, yes: true });
			expect(calls.some((c) => c.cmd === 'git' && c.args[0] === 'init')).toBe(false);
		} finally {
			rmSync(repoRoot, { recursive: true, force: true });
		}
	});

	it('refuses to overwrite an existing stack without --force', async () => {
		const { runner } = fakeRunner();
		await runSetupDev({ dir: root, runner, noStart: true, noKey: true, yes: true });

		await expect(
			runSetupDev({ dir: root, runner, noStart: true, noKey: true, yes: true })
		).rejects.toThrow(/already holds a dev stack/);
	});

	it('overwrites with --force', async () => {
		const { runner } = fakeRunner();
		await runSetupDev({ dir: root, runner, noStart: true, noKey: true, yes: true });

		await expect(
			runSetupDev({ dir: root, runner, noStart: true, noKey: true, yes: true, force: true })
		).resolves.toBeUndefined();
	});

	it('starts and seeds when not --no-start', async () => {
		const { runner, calls } = fakeRunner();

		await runSetupDev({ dir: root, runner, noKey: true, yes: true });

		expect(calls.some((c) => c.cmd === 'docker' && c.args.includes('up'))).toBe(true);
		expect(
			calls.some(
				(c) => c.cmd === 'docker' && c.args.includes('seed:dev') && c.args.includes('db_reset')
			)
		).toBe(true);
	});

	it('does not start with --no-start', async () => {
		const { runner, calls } = fakeRunner();

		await runSetupDev({ dir: root, runner, noStart: true, noKey: true, yes: true });

		expect(calls.some((c) => c.cmd === 'docker' && c.args.includes('up'))).toBe(false);
	});

	it('runs the connect step by default and skips it with --no-key', async () => {
		const { runner } = fakeRunner();
		const connect = vi.fn(async () => undefined);

		await runSetupDev({ dir: root, runner, yes: true, connect });
		expect(connect).toHaveBeenCalledWith('https://facet.localhost:3443');

		const { runner: runner2 } = fakeRunner();
		const connect2 = vi.fn(async () => undefined);
		await runSetupDev({
			dir: mkdtempSync(path.join(os.tmpdir(), 'facet-cli-setup-dev2-')),
			runner: runner2,
			yes: true,
			noKey: true,
			connect: connect2
		});
		expect(connect2).not.toHaveBeenCalled();
	});

	it('fails when docker is missing', async () => {
		const runner: Runner = (cmd, args) => {
			if (cmd === 'docker' && args[0] === 'compose' && args[1] === 'version') return 1;
			return 0;
		};

		await expect(
			runSetupDev({ dir: root, runner, noStart: true, noKey: true, yes: true })
		).rejects.toThrow(/Docker with Compose is required/);
	});

	it('fails when the stack start fails', async () => {
		const runner: Runner = (cmd, args) => {
			if (cmd === 'docker' && args.includes('up')) return 1;
			return 0;
		};

		await expect(runSetupDev({ dir: root, runner, noKey: true, yes: true })).rejects.toThrow(
			/docker compose up failed/
		);
	});
});
