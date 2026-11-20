// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { configPath } from '../../src/config.js';
import { appUrl, runDeploy } from '../../src/commands/deploy.js';

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

beforeEach(() => {
	root = mkdtempSync(path.join(os.tmpdir(), 'facet-cli-deploy-'));
	writeFileSync(
		configPath(root),
		JSON.stringify({
			app: 'plans',
			outDir: 'dist',
			spa: true,
			targets: { default: { url: INSTANCE } },
			defaultTarget: 'default'
		})
	);
});

afterEach(() => {
	rmSync(root, { recursive: true, force: true });
	vi.clearAllMocks();
});

function seedBuild(): void {
	mkdirSync(path.join(root, 'dist', 'assets'), { recursive: true });
	writeFileSync(path.join(root, 'dist', 'index.html'), '<h1>plans</h1>');
	writeFileSync(path.join(root, 'dist', 'assets', 'app.js'), 'console.log(1)');
}

describe('appUrl', () => {
	it('keeps https and adds no port for a plain https instance', () => {
		expect(appUrl('https://staging.facet.example.com', 'app.example.com')).toBe(
			'https://app.example.com'
		);
	});

	it('keeps http and the explicit port of the instance', () => {
		expect(appUrl('http://localhost:3000', 'my-app.localhost')).toBe(
			'http://my-app.localhost:3000'
		);
	});

	it('keeps http without a port when the instance has none', () => {
		expect(appUrl('http://localhost', 'my-app.localhost')).toBe('http://my-app.localhost');
	});

	it('drops an explicit default port, as the URL parser normalizes it away', () => {
		expect(appUrl('https://staging.facet.example.com:443', 'app.example.com')).toBe(
			'https://app.example.com'
		);
	});

	it('ignores a path on the instance URL', () => {
		expect(appUrl('https://facet.example.com/inst1/', 'app.example.com')).toBe(
			'https://app.example.com'
		);
	});
});

describe('deploy', () => {
	it('walks the build folder, uploads it activated by default, and prints the result', async () => {
		seedBuild();
		apiFake.resolveAppId.mockResolvedValue('app.App.01H');
		apiFake.readApp.mockResolvedValue({
			data: { host: 'plans.facet.example.com' },
			meta: { id: 'app.App.01H' }
		});
		apiFake.deploy.mockResolvedValue({ id: '01D', revision: 4, activated: true, files: 2 });
		const logs: string[] = [];
		vi.spyOn(console, 'log').mockImplementation((message) => logs.push(message));

		await runDeploy(root, {});

		expect(apiFake.deploy).toHaveBeenCalledTimes(1);
		const [appId, body, contentType] = apiFake.deploy.mock.calls[0] as unknown as [
			string,
			Uint8Array,
			string
		];
		expect(appId).toBe('app.App.01H');
		expect(contentType).toContain('multipart/form-data; boundary=');
		const text = new TextDecoder().decode(body);
		expect(text).toContain('"activate":true');
		expect(text).toContain('"spa":true');
		expect(logs.join('\n')).toContain('Deployed revision 4');
		expect(logs.join('\n')).toContain('Active at https://plans.facet.example.com');
	});

	it('plumbs --no-activate into the upload body', async () => {
		seedBuild();
		apiFake.resolveAppId.mockResolvedValue('app.App.01H');
		apiFake.readApp.mockResolvedValue({ data: {}, meta: { id: 'app.App.01H' } });
		apiFake.deploy.mockResolvedValue({ id: '01D', revision: 5, activated: false, files: 2 });
		vi.spyOn(console, 'log').mockImplementation(() => {});

		await runDeploy(root, { target: 'default', note: 'fix nav', activate: false });

		const [, body] = apiFake.deploy.mock.calls[0] as unknown as [string, Uint8Array];
		const text = new TextDecoder().decode(body);
		expect(text).toContain('"activate":false');
		expect(text).toContain('"note":"fix nav"');
	});

	it('prints the app URL with the scheme and port of the instance', async () => {
		writeFileSync(
			configPath(root),
			JSON.stringify({
				app: 'plans',
				outDir: 'dist',
				targets: { default: { url: 'http://localhost:3000' } },
				defaultTarget: 'default'
			})
		);
		seedBuild();
		apiFake.resolveAppId.mockResolvedValue('app.App.01H');
		apiFake.readApp.mockResolvedValue({
			data: { host: 'plans.localhost' },
			meta: { id: 'app.App.01H' }
		});
		apiFake.deploy.mockResolvedValue({ id: '01D', revision: 1, activated: true, files: 2 });
		const logs: string[] = [];
		vi.spyOn(console, 'log').mockImplementation((message) => logs.push(message));

		await runDeploy(root, {});

		expect(logs.join('\n')).toContain('Active at http://plans.localhost:3000');
	});
});
