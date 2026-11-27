// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { configPath } from '../../src/config.js';
import { readStoredKey } from '../../src/keyfile.js';
import { runConnect, API_KEY_NAME } from '../../src/commands/connect.js';

const INSTANCE = 'https://staging.facet.example.com';

const SESSION = {
	access_token: 'at',
	refresh_token: 'rt',
	client_id: 'cid',
	account: 'iam.Account.01A',
	role: 'iam.Roles.editor',
	expires_at: '2030-01-01T00:00:00Z'
};

const CREATED = {
	id: '06H1G3VT6CC3J5WVRTEBGGWYQ5',
	key: 'fct_6VBSG6PYWQDNFV3P7HQKXST2E9R',
	display_prefix: 'fct_6VBSG6',
	expires_at: null
};

let root: string;
const logs: string[] = [];

const login = vi.fn();
const me = vi.fn();
const createApiKey = vi.fn();
const apiFactory = vi.fn(() => ({
	me,
	createApiKey
})) as unknown as typeof import('../../src/api.js').createApi;

beforeEach(() => {
	root = mkdtempSync(path.join(os.tmpdir(), 'facet-cli-connect-'));
	logs.length = 0;
	writeFileSync(
		configPath(root),
		JSON.stringify({
			app: 'plans',
			outDir: 'dist',
			targets: { default: { url: INSTANCE } },
			defaultTarget: 'default'
		})
	);
	vi.spyOn(console, 'log').mockImplementation((message) => logs.push(message));
	login.mockResolvedValue(SESSION);
	me.mockResolvedValue({ account: { id: SESSION.account }, active_role: SESSION.role });
	createApiKey.mockResolvedValue(CREATED);
});

afterEach(() => {
	rmSync(root, { recursive: true, force: true });
	vi.restoreAllMocks();
	vi.clearAllMocks();
});

describe('connect', () => {
	it('signs in, issues a key for the active role, and stores it in the project folder', async () => {
		await runConnect(root, undefined, {
			login,
			apiFactory,
			promptFn: async () => 'y'
		});

		expect(login).toHaveBeenCalledWith({ instanceUrl: INSTANCE });
		expect(createApiKey).toHaveBeenCalledWith(API_KEY_NAME, SESSION.role);
		expect(readStoredKey(root, INSTANCE)).toEqual({
			key: CREATED.key,
			id: CREATED.id,
			display_prefix: CREATED.display_prefix,
			role: SESSION.role
		});
		expect(logs.join('\n')).toContain(`Signed in to ${INSTANCE}`);
		expect(logs.join('\n')).toContain('Issued API key fct_6VBSG6');
	});

	it('pins the key to the --role value, qualified from a bare name', async () => {
		await runConnect(root, undefined, {
			login,
			apiFactory,
			role: 'warehouse',
			promptFn: async () => 'y'
		});

		expect(createApiKey).toHaveBeenCalledWith(API_KEY_NAME, 'iam.Roles.warehouse');
		expect(readStoredKey(root, INSTANCE)?.role).toBe('iam.Roles.warehouse');
	});

	it('passes a qualified --role through unchanged', async () => {
		await runConnect(root, undefined, {
			login,
			apiFactory,
			role: 'iam.Roles.admin',
			promptFn: async () => 'y'
		});

		expect(createApiKey).toHaveBeenCalledWith(API_KEY_NAME, 'iam.Roles.admin');
	});

	it('prints the raw key once and names the apikey command', async () => {
		await runConnect(root, undefined, { login, apiFactory, promptFn: async () => 'y' });

		expect(logs.join('\n')).toContain('Authorization: Bearer $(facet-cli apikey)');
	});

	it('skips the key when the user answers no', async () => {
		await runConnect(root, undefined, { login, apiFactory, promptFn: async () => '' });

		expect(login).toHaveBeenCalled();
		expect(createApiKey).not.toHaveBeenCalled();
		expect(readStoredKey(root, INSTANCE)).toBeUndefined();
		expect(logs.join('\n')).toContain('Left no API key');
	});

	it('asks for the Facet URL when there is no config', async () => {
		rmSync(configPath(root));

		await runConnect(root, undefined, {
			login,
			apiFactory,
			promptFn: async () => INSTANCE
		});

		expect(login).toHaveBeenCalledWith({ instanceUrl: INSTANCE });
	});

	it('rejects a --target name when no config exists', async () => {
		rmSync(configPath(root));

		await expect(
			runConnect(root, 'staging', { login, apiFactory, promptFn: async () => '' })
		).rejects.toThrow(/No facet.config.json/);
		expect(login).not.toHaveBeenCalled();
	});
});
