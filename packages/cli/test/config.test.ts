// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { ConfigError, configPath, loadConfig, resolveTarget } from '../src/config.js';

let root: string;

beforeEach(() => {
	root = mkdtempSync(path.join(os.tmpdir(), 'facet-cli-config-'));
});

afterEach(() => {
	rmSync(root, { recursive: true, force: true });
});

function writeConfig(json: unknown): void {
	writeFileSync(configPath(root), JSON.stringify(json, null, '\t'));
}

const BASE_CONFIG = {
	app: 'brw-plans',
	outDir: 'build',
	spa: true,
	targets: {
		staging: { url: 'https://staging.facet.example.com' },
		prod: { url: 'https://facet.example.com' }
	},
	defaultTarget: 'staging'
};

describe('loadConfig', () => {
	it('loads a valid config', () => {
		writeConfig(BASE_CONFIG);

		const config = loadConfig(root);

		expect(config).toEqual(BASE_CONFIG);
	});

	it('applies the spa default of true', () => {
		writeConfig({ app: 'brw-plans', outDir: 'build' });

		const config = loadConfig(root);

		expect(config.spa).toBe(true);
	});

	it('rejects a missing config file with an init hint', () => {
		expect(() => loadConfig(root)).toThrow(ConfigError);
		expect(() => loadConfig(root)).toThrow(/init/);
	});

	it('rejects invalid JSON', () => {
		writeFileSync(configPath(root), '{ app: ');

		expect(() => loadConfig(root)).toThrow(ConfigError);
		expect(() => loadConfig(root)).toThrow(/not valid JSON/);
	});

	it('rejects a JSON root that is not an object', () => {
		writeConfig(['app']);

		expect(() => loadConfig(root)).toThrow(/must hold a JSON object/);
	});

	it('rejects a config with no app value', () => {
		writeConfig({ outDir: 'build' });

		expect(() => loadConfig(root)).toThrow(/"app"/);
	});

	it('rejects a config with no outDir value', () => {
		writeConfig({ app: 'brw-plans' });

		expect(() => loadConfig(root)).toThrow(/"outDir"/);
	});

	it('rejects a non-boolean spa value', () => {
		writeConfig({ app: 'brw-plans', outDir: 'build', spa: 'yes' });

		expect(() => loadConfig(root)).toThrow(/"spa" must be true or false/);
	});

	it('rejects a target entry with no url value', () => {
		writeConfig({ app: 'brw-plans', outDir: 'build', targets: { prod: {} } });

		expect(() => loadConfig(root)).toThrow(/Target "prod"/);
	});
});

describe('resolveTarget', () => {
	it('uses the explicit target name', () => {
		const config = loadConfig(rootWith(BASE_CONFIG));

		expect(resolveTarget(config, 'prod')).toEqual({
			name: 'prod',
			url: 'https://facet.example.com'
		});
	});

	it('falls back to defaultTarget', () => {
		const config = loadConfig(rootWith(BASE_CONFIG));

		expect(resolveTarget(config)).toEqual({
			name: 'staging',
			url: 'https://staging.facet.example.com'
		});
	});

	it('rejects an unknown target name and lists the available names', () => {
		const config = loadConfig(rootWith(BASE_CONFIG));

		expect(() => resolveTarget(config, 'dev')).toThrow(/Available targets: staging, prod/);
	});

	it('rejects an unknown defaultTarget and lists the available names', () => {
		const config = loadConfig(rootWith({ ...BASE_CONFIG, defaultTarget: 'dev' }));

		expect(() => resolveTarget(config)).toThrow(/Unknown defaultTarget "dev"/);
	});

	it('rejects a run with no selection when targets are defined', () => {
		const config = loadConfig(
			rootWith({ app: 'brw-plans', outDir: 'build', targets: BASE_CONFIG.targets })
		);

		expect(() => resolveTarget(config)).toThrow(/No target selected/);
	});

	it('rejects a run when the config defines no targets at all', () => {
		const config = loadConfig(rootWith({ app: 'brw-plans', outDir: 'build' }));

		expect(() => resolveTarget(config)).toThrow(/defines no targets/);
	});
});

/** Writes the config into a fresh root and returns the root path. */
function rootWith(json: unknown): string {
	const target = path.join(root, 'project');
	mkdirSync(target, { recursive: true });
	writeFileSync(configPath(target), JSON.stringify(json, null, '\t'));
	return target;
}
