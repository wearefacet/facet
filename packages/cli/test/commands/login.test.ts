// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { configPath } from '../../src/config.js';
import { runLogin } from '../../src/commands/login.js';

const INSTANCE = 'https://staging.facet.example.com';

const loginFlow = vi.fn();

vi.mock('../../src/login.js', () => ({
	login: (...args: unknown[]) => loginFlow(...args)
}));

let root: string;
const logs: string[] = [];

beforeEach(() => {
	root = mkdtempSync(path.join(os.tmpdir(), 'facet-cli-login-'));
	vi.spyOn(console, 'log').mockImplementation((message) => logs.push(message));
});

afterEach(() => {
	rmSync(root, { recursive: true, force: true });
	vi.restoreAllMocks();
	vi.clearAllMocks();
});

const SESSION = {
	access_token: 'at',
	refresh_token: 'rt',
	account: 'iam.Account.01A',
	role: 'admin',
	expires_at: '2030-01-01T00:00:00Z'
};

describe('login', () => {
	it('signs in to the configured target and prints the outcome', async () => {
		const { writeFileSync } = await import('node:fs');
		writeFileSync(
			configPath(root),
			JSON.stringify({
				app: 'plans',
				outDir: 'dist',
				targets: { default: { url: INSTANCE } },
				defaultTarget: 'default'
			})
		);
		loginFlow.mockResolvedValue(SESSION);

		await runLogin(root, undefined, { promptFn: async () => 'unused' });

		expect(loginFlow).toHaveBeenCalledWith({ instanceUrl: INSTANCE });
		expect(logs.join('\n')).toContain('Signed in to ' + INSTANCE);
		expect(logs.join('\n')).toContain('role admin');
	});

	it('asks for the instance URL when there is no config', async () => {
		loginFlow.mockResolvedValue(SESSION);

		await runLogin(root, undefined, {
			promptFn: async () => INSTANCE,
			flow: loginFlow as (input: { instanceUrl: string }) => Promise<typeof SESSION>
		});

		expect(loginFlow).toHaveBeenCalledWith({ instanceUrl: INSTANCE });
	});

	it('re-asks until the URL is non-empty', async () => {
		const answers = ['', INSTANCE];
		loginFlow.mockResolvedValue(SESSION);

		await runLogin(root, undefined, {
			promptFn: async () => answers.shift() ?? INSTANCE,
			flow: loginFlow as (input: { instanceUrl: string }) => Promise<typeof SESSION>
		});

		expect(loginFlow).toHaveBeenCalledTimes(1);
	});

	it('rejects a --target name when no config exists', async () => {
		await expect(runLogin(root, 'staging', { promptFn: async () => '' })).rejects.toThrow(
			/No facet.config.json/
		);
		expect(loginFlow).not.toHaveBeenCalled();
	});
});
