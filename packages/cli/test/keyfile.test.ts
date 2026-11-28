// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { mkdtempSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
	LOCAL_CONFIG_FILE,
	LocalConfigError,
	localConfigPath,
	readLocalConfig,
	readStoredKey,
	writeStoredKey,
	type StoredKey
} from '../src/keyfile.js';

const INSTANCE = 'https://staging.facet.example.com';
const OTHER = 'https://facet.example.com';

const KEY: StoredKey = {
	key: 'fct_6VBSG6PYWQDNFV3P7HQKXST2E9R',
	id: '06H1G3VT6CC3J5WVRTEBGGWYQ5',
	display_prefix: 'fct_6VBSG6',
	role: 'iam.Roles.editor'
};

let root: string;

beforeEach(() => {
	root = mkdtempSync(path.join(os.tmpdir(), 'facet-cli-keyfile-'));
});

afterEach(() => {
	rmSync(root, { recursive: true, force: true });
});

describe('keyfile', () => {
	it('reads a missing file as empty', () => {
		expect(readLocalConfig(root)).toEqual({ apiKeys: {} });
		expect(readStoredKey(root, INSTANCE)).toBeUndefined();
	});

	it('writes a key with mode 600 and reads it back', () => {
		writeStoredKey(root, INSTANCE, KEY);

		expect(readStoredKey(root, INSTANCE)).toEqual(KEY);
		const mode = statSync(localConfigPath(root)).mode & 0o777;
		expect(mode).toBe(0o600);
	});

	it('keys by instance and keeps the other instances intact', () => {
		writeStoredKey(root, INSTANCE, KEY);
		writeStoredKey(root, OTHER, { ...KEY, key: 'fct_OTHER', id: 'other' });

		expect(readStoredKey(root, INSTANCE)?.key).toBe(KEY.key);
		expect(readStoredKey(root, OTHER)?.key).toBe('fct_OTHER');
	});

	it('normalizes trailing slashes on the instance URL', () => {
		writeStoredKey(root, `${INSTANCE}/`, KEY);

		expect(readStoredKey(root, INSTANCE)?.key).toBe(KEY.key);
	});

	it('keeps expires_at when present', () => {
		const expiring = { ...KEY, expires_at: '2030-01-01T00:00:00Z' };
		writeStoredKey(root, INSTANCE, expiring);

		expect(readStoredKey(root, INSTANCE)?.expires_at).toBe('2030-01-01T00:00:00Z');
	});

	it('rejects malformed JSON', () => {
		writeFileSync(localConfigPath(root), '{not json');

		expect(() => readLocalConfig(root)).toThrow(LocalConfigError);
	});

	it('rejects a non-object root', () => {
		writeFileSync(localConfigPath(root), '[]');

		expect(() => readLocalConfig(root)).toThrow(/must hold a JSON object/);
	});

	it('rejects a key entry without a token', () => {
		writeFileSync(
			localConfigPath(root),
			JSON.stringify({ apiKeys: { [INSTANCE]: { id: 'x', display_prefix: 'p', role: 'r' } } })
		);

		expect(() => readLocalConfig(root)).toThrow(/has no "key" value/);
	});

	it('writes the documented file name', () => {
		writeStoredKey(root, INSTANCE, KEY);

		expect(path.basename(localConfigPath(root))).toBe(LOCAL_CONFIG_FILE);
		expect(JSON.parse(readFileSync(localConfigPath(root), 'utf8'))).toEqual({
			apiKeys: { [INSTANCE]: KEY }
		});
	});
});
