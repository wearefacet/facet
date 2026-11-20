// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { existsSync, mkdtempSync, readFileSync, rmSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { configPath, ConfigError } from '../../src/config.js';
import { runInit } from '../../src/commands/init.js';

const apiFake = {
	request: vi.fn(),
	resolveAppId: vi.fn(),
	findAppId: vi.fn(),
	createApp: vi.fn(),
	readApp: vi.fn(),
	listDeployments: vi.fn(),
	setActiveDeployment: vi.fn(),
	deploy: vi.fn()
};

vi.mock('../../src/api.js', () => ({
	ApiError: class ApiError extends Error {},
	createApi: () => apiFake
}));

vi.mock('../../src/auth.js', () => ({
	readSession: vi.fn(),
	AuthError: class AuthError extends Error {}
}));

import { readSession, type StoredSession } from '../../src/auth.js';

const INSTANCE = 'https://staging.facet.example.com';

let root: string;
const logs: string[] = [];
const errors: string[] = [];

beforeEach(() => {
	root = mkdtempSync(path.join(os.tmpdir(), 'facet-cli-init-'));
	logs.length = 0;
	errors.length = 0;
	vi.spyOn(console, 'log').mockImplementation((message) => logs.push(message));
	vi.spyOn(console, 'error').mockImplementation((message) => errors.push(message));
});

afterEach(() => {
	rmSync(root, { recursive: true, force: true });
	vi.restoreAllMocks();
	vi.clearAllMocks();
	stubIsTTY(originalIsTTY);
});

type Ask = (question: string, fallback?: string) => Promise<string>;

const originalIsTTY = process.stdin.isTTY;

/** Forces `process.stdin.isTTY` for one test; `afterEach` puts back the real value. */
function stubIsTTY(value: boolean | undefined): void {
	Object.defineProperty(process.stdin, 'isTTY', { value, configurable: true });
}

/** A prompt double that answers fixed values in order, falling back when the answer is empty. */
function scripted(answers: string[]): Ask {
	let index = 0;
	return async (_question, fallback) => {
		const answer = answers[index++];
		if (answer !== undefined && answer !== '') return answer;
		return fallback ?? '';
	};
}

/** A prompt double driven by named answers for the full flow. */
function flowWith({ slug, confirmCreate }: { slug: string; confirmCreate: string }): Ask {
	return async (question, fallback) => {
		if (question === 'App slug') return slug;
		if (question === 'Build folder') return fallback ?? '';
		if (question === 'Instance URL (empty to skip)') return INSTANCE;
		if (question.startsWith('No app')) return confirmCreate;
		throw new Error(`unexpected question: ${question}`);
	};
}

function storedSession(): StoredSession {
	return {
		access_token: 'at',
		refresh_token: 'rt',
		account: 'iam.Account.01A',
		role: 'admin',
		expires_at: '2030-01-01T00:00:00Z'
	};
}

function readWrittenConfig(): Record<string, unknown> {
	expect(existsSync(configPath(root))).toBe(true);
	return JSON.parse(readFileSync(configPath(root), 'utf8')) as Record<string, unknown>;
}

describe('init', () => {
	it('writes the config with an instance target and defaults', async () => {
		vi.mocked(readSession).mockReturnValue(undefined);

		await runInit(root, { promptFn: scripted(['plans', '', INSTANCE]) });

		expect(readWrittenConfig()).toEqual({
			app: 'plans',
			outDir: 'dist',
			spa: true,
			targets: { default: { url: INSTANCE } },
			defaultTarget: 'default'
		});
	});

	it('writes a config without targets when the instance is skipped', async () => {
		vi.mocked(readSession).mockReturnValue(undefined);

		await runInit(root, { promptFn: scripted(['plans', 'build', '']) });

		expect(readWrittenConfig()).toMatchObject({
			app: 'plans',
			outDir: 'build',
			spa: true,
			targets: {}
		});
		expect(logs.join('\n')).toContain('login');
	});

	it('fails loud on non-interactive stdin when no promptFn is injected', async () => {
		stubIsTTY(undefined);

		const error: unknown = await runInit(root, { readStdinFn: async () => '' }).then(
			() => undefined,
			(caught: unknown) => caught
		);

		expect(error).toBeInstanceOf(ConfigError);
		expect((error as Error).message).toMatch(/interactive terminal/);
		expect(existsSync(configPath(root))).toBe(false);
	});

	it('writes the config from flags without prompting or reading stdin', async () => {
		vi.mocked(readSession).mockReturnValue(undefined);
		const readStdinFn = vi.fn(async () => '');

		await runInit(root, {
			yes: true,
			app: 'plans',
			build: 'build',
			server: INSTANCE,
			readStdinFn
		});

		expect(readWrittenConfig()).toEqual({
			app: 'plans',
			outDir: 'build',
			spa: true,
			targets: { default: { url: INSTANCE } },
			defaultTarget: 'default'
		});
		expect(readStdinFn).not.toHaveBeenCalled();
	});

	it('defaults the build folder and skips the target when the flags omit them', async () => {
		vi.mocked(readSession).mockReturnValue(undefined);

		await runInit(root, { yes: true, app: 'plans' });

		expect(readWrittenConfig()).toEqual({
			app: 'plans',
			outDir: 'dist',
			spa: true,
			targets: {}
		});
	});

	it('reads the three answers from piped stdin', async () => {
		vi.mocked(readSession).mockReturnValue(undefined);
		stubIsTTY(undefined);

		await runInit(root, { readStdinFn: async () => `plans\nbuild\n${INSTANCE}\n` });

		expect(readWrittenConfig()).toEqual({
			app: 'plans',
			outDir: 'build',
			spa: true,
			targets: { default: { url: INSTANCE } },
			defaultTarget: 'default'
		});
	});

	it('fails with a clear error when stdin is empty and no flags are given', async () => {
		stubIsTTY(undefined);

		const error: unknown = await runInit(root, { readStdinFn: async () => '' }).then(
			() => undefined,
			(caught: unknown) => caught
		);

		expect(error).toBeInstanceOf(ConfigError);
		expect((error as Error).message).toMatch(/interactive terminal/);
		expect(existsSync(configPath(root))).toBe(false);
	});

	it('does not prompt when --yes is set without answers', async () => {
		stubIsTTY(true);

		const error: unknown = await runInit(root, { yes: true }).then(
			() => undefined,
			(caught: unknown) => caught
		);

		expect(error).toBeInstanceOf(ConfigError);
		expect((error as Error).message).toMatch(/interactive terminal/);
		expect(existsSync(configPath(root))).toBe(false);
	});

	it('lets an injected promptFn run on non-interactive stdin', async () => {
		vi.mocked(readSession).mockReturnValue(undefined);
		stubIsTTY(undefined);

		await runInit(root, { promptFn: scripted(['plans', 'dist', '']) });

		expect(readWrittenConfig()).toMatchObject({ app: 'plans', outDir: 'dist' });
	});

	it('refuses to overwrite an existing config', async () => {
		const { writeFileSync } = await import('node:fs');
		writeFileSync(configPath(root), '{}');

		await expect(runInit(root, { promptFn: scripted([]) })).rejects.toThrow(/already exists/);
	});

	it('re-asks when the slug is empty', async () => {
		vi.mocked(readSession).mockReturnValue(undefined);

		await runInit(root, { promptFn: scripted(['', 'plans', 'dist', '']) });

		expect(readWrittenConfig()).toMatchObject({ app: 'plans', outDir: 'dist' });
	});

	it('reports an existing app when a session is stored', async () => {
		vi.mocked(readSession).mockReturnValue(storedSession());
		apiFake.findAppId.mockResolvedValue('app.App.01H');
		apiFake.readApp.mockResolvedValue({
			data: { display_name: 'Plans' },
			meta: { id: 'app.App.01H' }
		});

		await runInit(root, { promptFn: scripted(['plans', 'dist', INSTANCE]) });

		expect(logs.join('\n')).toContain('already exists');
		expect(apiFake.createApp).not.toHaveBeenCalled();
	});

	it('creates the app when the user accepts the offer', async () => {
		vi.mocked(readSession).mockReturnValue(storedSession());
		apiFake.findAppId.mockResolvedValue(undefined);
		apiFake.createApp.mockResolvedValue({
			data: { name: 'plans' },
			meta: { id: 'app.App.01H', display_name: 'plans' }
		});

		await runInit(root, {
			promptFn: flowWith({ slug: 'plans', confirmCreate: 'y' })
		});

		expect(apiFake.createApp).toHaveBeenCalledWith('plans');
		expect(logs.join('\n')).toContain('Created app');
		expect(logs.join('\n')).toContain('draft');
	});

	it('creates the app without asking when --yes is set', async () => {
		vi.mocked(readSession).mockReturnValue(storedSession());
		apiFake.findAppId.mockResolvedValue(undefined);
		apiFake.createApp.mockResolvedValue({
			data: { name: 'plans' },
			meta: { id: 'app.App.01H', display_name: 'Plans App' }
		});

		await runInit(root, { yes: true, app: 'plans', build: 'dist', server: INSTANCE });

		expect(apiFake.createApp).toHaveBeenCalledWith('plans');
		expect(logs.join('\n')).toContain('Created app');
	});

	it('leaves the app uncreated without --yes on non-interactive stdin', async () => {
		vi.mocked(readSession).mockReturnValue(storedSession());
		apiFake.findAppId.mockResolvedValue(undefined);
		stubIsTTY(undefined);

		await runInit(root, { app: 'plans', build: 'dist', server: INSTANCE });

		expect(apiFake.createApp).not.toHaveBeenCalled();
		expect(logs.join('\n')).toContain('--yes');
	});

	it('keeps the config when the user declines the create offer', async () => {
		vi.mocked(readSession).mockReturnValue(storedSession());
		apiFake.findAppId.mockResolvedValue(undefined);

		await runInit(root, {
			promptFn: flowWith({ slug: 'plans', confirmCreate: 'n' })
		});

		expect(logs.join('\n')).toContain('Left the app uncreated');
		expect(apiFake.createApp).not.toHaveBeenCalled();
	});

	it('hints at login when no session is stored for the instance', async () => {
		vi.mocked(readSession).mockReturnValue(undefined);

		await runInit(root, { promptFn: scripted(['plans', 'dist', INSTANCE]) });

		expect(logs.join('\n')).toContain('No stored session');
		expect(apiFake.findAppId).not.toHaveBeenCalled();
	});

	it('never touches the API without a session (offline safe)', async () => {
		vi.mocked(readSession).mockReturnValue(undefined);

		await runInit(root, { promptFn: scripted(['plans', 'dist', '']) });

		expect(apiFake.findAppId).not.toHaveBeenCalled();
	});
});
