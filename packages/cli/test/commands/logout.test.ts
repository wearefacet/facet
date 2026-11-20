// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { configPath } from '../../src/config.js';
import { runLogout } from '../../src/commands/logout.js';

const removeSession = vi.fn();

vi.mock('../../src/auth.js', () => ({
	removeSession: (...args: unknown[]) => removeSession(...args)
}));

let root: string;
const logs: string[] = [];

beforeEach(() => {
	root = mkdtempSync(path.join(os.tmpdir(), 'facet-cli-logout-'));
	logs.length = 0;
	writeFileSync(
		configPath(root),
		JSON.stringify({
			app: 'plans',
			outDir: 'dist',
			targets: { default: { url: 'https://staging.facet.example.com' } },
			defaultTarget: 'default'
		})
	);
	vi.spyOn(console, 'log').mockImplementation((message) => logs.push(message));
});

afterEach(() => {
	rmSync(root, { recursive: true, force: true });
	vi.restoreAllMocks();
	vi.clearAllMocks();
});

describe('logout', () => {
	it('removes the stored session for the configured instance', async () => {
		removeSession.mockReturnValue(true);

		await runLogout(root);

		expect(removeSession).toHaveBeenCalledWith('https://staging.facet.example.com');
		expect(logs[0]).toContain('Removed the stored session');
	});

	it('stays calm when no session is stored', async () => {
		removeSession.mockReturnValue(false);

		await runLogout(root);

		expect(logs[0]).toContain('No stored session');
	});

	it('honours --target', async () => {
		const { writeFileSync } = await import('node:fs');
		writeFileSync(
			configPath(root),
			JSON.stringify({
				app: 'plans',
				outDir: 'dist',
				targets: {
					default: { url: 'https://staging.facet.example.com' },
					prod: { url: 'https://facet.example.com' }
				}
			})
		);
		removeSession.mockReturnValue(true);

		await runLogout(root, 'prod');

		expect(removeSession).toHaveBeenCalledWith('https://facet.example.com');
	});
});
