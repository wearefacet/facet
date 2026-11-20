// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { AuthError } from '../../src/auth.js';
import { configPath } from '../../src/config.js';
import { runWhoami } from '../../src/commands/whoami.js';

const INSTANCE = 'https://staging.facet.example.com';

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
	ApiError: class ApiError extends Error {
		status: number;
		constructor(message: string, status: number) {
			super(message);
			this.status = status;
		}
	},
	createApi: () => apiFake
}));

vi.mock('../../src/auth.js', () => ({
	AuthError: class AuthError extends Error {}
}));

let root: string;

beforeEach(() => {
	root = mkdtempSync(path.join(os.tmpdir(), 'facet-cli-whoami-'));
	writeFileSync(
		configPath(root),
		JSON.stringify({
			app: 'plans',
			outDir: 'dist',
			targets: { default: { url: INSTANCE } },
			defaultTarget: 'default'
		})
	);
});

afterEach(() => {
	rmSync(root, { recursive: true, force: true });
	vi.clearAllMocks();
});

describe('whoami', () => {
	it('prints instance, account, role, and the active revision', async () => {
		apiFake.request.mockResolvedValue({
			account: { id: 'iam.Account.01A', email: 'op@example.com' },
			active_role: 'admin'
		});
		apiFake.resolveAppId.mockResolvedValue('app.App.01H');
		apiFake.readApp.mockResolvedValue({
			data: { display_name: 'Plans', active_deployment: 'app.Deployment.2' },
			meta: { id: 'app.App.01H' }
		});
		apiFake.listDeployments.mockResolvedValue({
			data: [
				{ data: { revision: 2 }, meta: { id: '2' } },
				{ data: { revision: 1 }, meta: { id: '1' } }
			],
			meta: { count: 2, more: false }
		});
		const logs: string[] = [];
		vi.spyOn(console, 'log').mockImplementation((message) => logs.push(message));

		await runWhoami(root);

		expect(logs).toEqual([
			`instance: ${INSTANCE}`,
			'account:  op@example.com',
			'role:     admin',
			'app:      plans — revision 2 active (2)'
		]);
		expect(apiFake.request).toHaveBeenCalledWith('/Api/iam/me');
	});

	it('reports an app with no deployment yet', async () => {
		apiFake.request.mockResolvedValue({
			account: { id: 'op@example.com' },
			active_role: 'viewer'
		});
		apiFake.resolveAppId.mockResolvedValue('app.App.01H');
		apiFake.readApp.mockResolvedValue({ data: {}, meta: { id: 'app.App.01H' } });
		const logs: string[] = [];
		vi.spyOn(console, 'log').mockImplementation((message) => logs.push(message));

		await runWhoami(root);

		expect(logs.at(-1)).toBe('app:      plans (no deployment yet)');
	});

	it('propagates a session error that survives refresh', async () => {
		apiFake.request.mockRejectedValue(
			new AuthError(`The session for ${INSTANCE} is no longer valid. Run login.`)
		);

		await expect(runWhoami(root)).rejects.toThrow(/Run login/);
	});
});
