// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { configPath } from '../../src/config.js';
import { runReleases } from '../../src/commands/releases.js';
import { runRollback } from '../../src/commands/rollback.js';

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
	ApiError: class ApiError extends Error {},
	createApi: () => apiFake
}));

let root: string;
const logs: string[] = [];

beforeEach(() => {
	root = mkdtempSync(path.join(os.tmpdir(), 'facet-cli-releases-'));
	logs.length = 0;
	vi.spyOn(console, 'log').mockImplementation((message) =>
		logs.push(message === undefined ? '' : String(message))
	);
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
	vi.restoreAllMocks();
	vi.clearAllMocks();
});

function seedList(): void {
	apiFake.resolveAppId.mockResolvedValue('app.App.01H');
	apiFake.readApp.mockResolvedValue({
		// The stored reference is qualified; the list rows carry the bare
		// row id — the shapes the API really returns.
		data: { active_deployment: 'app.Deployment.2' },
		meta: { id: 'app.App.01H' }
	});
	apiFake.listDeployments.mockResolvedValue({
		data: [
			{
				data: { revision: 3, note: 'new nav' },
				meta: { id: '3', created_at: '2026-09-18T10:00:00Z' }
			},
			{
				data: { revision: 2 },
				meta: { id: '2', created_at: '2026-09-17T10:00:00Z' }
			}
		],
		meta: { count: 2, more: false }
	});
}

describe('releases', () => {
	it('renders revisions with the active marker', async () => {
		seedList();

		await runReleases(root);

		expect(logs).toEqual([
			'  3  3  new nav  2026-09-18T10:00:00Z',
			'* 2  2  2026-09-17T10:00:00Z',
			'',
			'(* marks the active deployment)'
		]);
	});

	it('says so when the app has no deployments', async () => {
		apiFake.resolveAppId.mockResolvedValue('app.App.01H');
		apiFake.readApp.mockResolvedValue({ data: {}, meta: { id: 'app.App.01H' } });
		apiFake.listDeployments.mockResolvedValue({
			data: [],
			meta: { count: 0, more: false }
		});

		await runReleases(root);

		expect(logs[0]).toContain('No deployments');
	});
});

describe('rollback', () => {
	it('PATCHes the active deployment to the given revision', async () => {
		seedList();
		apiFake.setActiveDeployment.mockResolvedValue({ data: {}, meta: { id: 'app.App.01H' } });

		await runRollback(root, '2');

		expect(apiFake.setActiveDeployment).toHaveBeenCalledWith('app.App.01H', 'app.Deployment.2');
		expect(logs[0]).toContain('Revision 2');
	});

	it('fails with the known revisions when the revision is unknown', async () => {
		seedList();

		await expect(runRollback(root, '9')).rejects.toThrow(
			/No deployment with revision 9\. Known revisions: 3, 2\./
		);
		expect(apiFake.setActiveDeployment).not.toHaveBeenCalled();
	});

	it('rejects a non-numeric revision without touching the API', async () => {
		await expect(runRollback(root, 'latest')).rejects.toThrow(/not a revision number/);
		expect(apiFake.resolveAppId).not.toHaveBeenCalled();
	});
});
