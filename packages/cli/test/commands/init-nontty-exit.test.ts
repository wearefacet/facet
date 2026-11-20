// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

// B-156 — non-interactive `facet init` must never exit 0 without the
// config artifact. End to end through the real program: the non-TTY guard
// in `runInit` throws `ConfigError`, the shared error boundary prints it
// to stderr and fails the run (exit code 1), and no config file lands.
//
// F07-02 — the same program accepts flags and piped stdin, so an agent can
// scaffold a project without a terminal.

import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { Readable } from 'node:stream';
import { afterEach, describe, expect, it, vi } from 'vitest';
import { configPath } from '../../src/config.js';
import { createProgram } from '../../src/index.js';

// Keep the app check offline: no stored session means no network call.
vi.mock('../../src/auth.js', () => ({
	readSession: () => undefined,
	AuthError: class AuthError extends Error {}
}));

let root: string;
const originalStdin = process.stdin;
const originalCwd = process.cwd();
const originalExitCode = process.exitCode;
const errors: string[] = [];
const errorSpy = vi.spyOn(console, 'error').mockImplementation((message) => errors.push(message));

afterEach(() => {
	process.chdir(originalCwd);
	rmSync(root, { recursive: true, force: true });
	Object.defineProperty(process, 'stdin', { value: originalStdin, configurable: true });
	process.exitCode = originalExitCode;
	errorSpy.mockClear();
	errors.length = 0;
});

/** Replaces stdin with a closed stream that yields `input`, then EOF. */
function stubStdin(input: string): void {
	const stream = Readable.from(input === '' ? [] : [input]);
	Object.defineProperty(process, 'stdin', { value: stream, configurable: true });
}

/** Runs one command through commander and waits for its async action. */
async function runProgram(...args: string[]): Promise<void> {
	const program = createProgram();
	const previousArgv = process.argv;
	process.argv = ['node', 'facet-cli', ...args];
	try {
		await program.parseAsync(process.argv);
	} finally {
		process.argv = previousArgv;
	}
}

function readWrittenConfig(): Record<string, unknown> {
	return JSON.parse(readFileSync(configPath(root), 'utf8')) as Record<string, unknown>;
}

describe('facet init on non-interactive stdin (B-156)', () => {
	it('fails the run instead of exiting 0 without the config artifact', async () => {
		root = mkdtempSync(path.join(os.tmpdir(), 'facet-cli-init-exit-'));
		process.chdir(root);
		stubStdin('');
		process.exitCode = undefined;

		await runProgram('init');

		expect(process.exitCode).toBe(1);
		expect(errors.join('\n')).toMatch(/interactive terminal/);
		expect(existsSync(configPath(root))).toBe(false);
	});
});

describe('facet init without a terminal (F07-02)', () => {
	it('writes the config from flags and exits 0', async () => {
		root = mkdtempSync(path.join(os.tmpdir(), 'facet-cli-init-flags-'));
		process.chdir(root);
		stubStdin('');
		process.exitCode = undefined;

		await runProgram(
			'init',
			'--yes',
			'--app',
			'slug',
			'--build',
			'dist',
			'--server',
			'https://facet.localhost:3443'
		);

		expect(process.exitCode).toBeUndefined();
		expect(readWrittenConfig()).toEqual({
			app: 'slug',
			outDir: 'dist',
			spa: true,
			targets: { default: { url: 'https://facet.localhost:3443' } },
			defaultTarget: 'default'
		});
	});

	it('writes the config from piped stdin and exits 0', async () => {
		root = mkdtempSync(path.join(os.tmpdir(), 'facet-cli-init-stdin-'));
		process.chdir(root);
		stubStdin('slug\ndist\nhttps://facet.localhost:3443\n');
		process.exitCode = undefined;

		await runProgram('init');

		expect(process.exitCode).toBeUndefined();
		expect(readWrittenConfig()).toEqual({
			app: 'slug',
			outDir: 'dist',
			spa: true,
			targets: { default: { url: 'https://facet.localhost:3443' } },
			defaultTarget: 'default'
		});
	});
});
