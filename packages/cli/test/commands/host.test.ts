// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { configPath } from '../../src/config.js';
import { runHost } from '../../src/commands/host.js';

const INSTANCE = 'https://staging.facet.example.com';

let root: string;
let written: string;

beforeEach(() => {
	root = mkdtempSync(path.join(os.tmpdir(), 'facet-cli-host-'));
	written = '';
	writeFileSync(
		configPath(root),
		JSON.stringify({
			app: 'plans',
			outDir: 'dist',
			targets: {
				default: { url: INSTANCE },
				prod: { url: 'https://facet.example.com/' }
			},
			defaultTarget: 'default'
		})
	);
	vi.spyOn(process.stdout, 'write').mockImplementation((chunk) => {
		written += String(chunk);
		return true;
	});
});

afterEach(() => {
	rmSync(root, { recursive: true, force: true });
	vi.restoreAllMocks();
});

describe('host', () => {
	it('prints the instance URL for the default target, nothing else', async () => {
		await runHost(root);

		expect(written).toBe(`${INSTANCE}\n`);
	});

	it('honours --target', async () => {
		await runHost(root, 'prod');

		expect(written).toBe('https://facet.example.com\n');
	});

	it('fails when the target is unknown', async () => {
		await expect(runHost(root, 'nope')).rejects.toThrow(/Unknown target "nope"/);
		expect(written).toBe('');
	});
});
