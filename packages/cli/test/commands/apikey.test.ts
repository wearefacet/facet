// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import { configPath } from '../../src/config.js';
import { writeStoredKey } from '../../src/keyfile.js';
import { runApikey } from '../../src/commands/apikey.js';

const INSTANCE = 'https://staging.facet.example.com';

const KEY = {
	key: 'fct_6VBSG6PYWQDNFV3P7HQKXST2E9R',
	id: '06H1G3VT6CC3J5WVRTEBGGWYQ5',
	display_prefix: 'fct_6VBSG6',
	role: 'iam.Roles.editor'
};

let root: string;
let written: string;

beforeEach(() => {
	root = mkdtempSync(path.join(os.tmpdir(), 'facet-cli-apikey-'));
	written = '';
	writeFileSync(
		configPath(root),
		JSON.stringify({
			app: 'plans',
			outDir: 'dist',
			targets: {
				default: { url: INSTANCE },
				prod: { url: 'https://facet.example.com' }
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

describe('apikey', () => {
	it('prints the stored key for the default target, nothing else', async () => {
		writeStoredKey(root, INSTANCE, KEY);

		await runApikey(root);

		expect(written).toBe(`${KEY.key}\n`);
	});

	it('honours --target', async () => {
		writeStoredKey(root, 'https://facet.example.com', { ...KEY, key: 'fct_PROD' });

		await runApikey(root, 'prod');

		expect(written).toBe('fct_PROD\n');
	});

	it('fails when no key is stored', async () => {
		await expect(runApikey(root)).rejects.toThrow(/No API key stored/);
		expect(written).toBe('');
	});

	it('fails when the stored key has expired', async () => {
		writeStoredKey(root, INSTANCE, { ...KEY, expires_at: '2000-01-01T00:00:00Z' });

		await expect(runApikey(root)).rejects.toThrow(/expired/);
	});
});
