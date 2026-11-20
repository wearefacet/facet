// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { readFileSync } from 'node:fs';
import path from 'node:path';
import { errorMessage } from './util.js';

/** One named Facet instance the CLI can talk to. */
export interface TargetConfig {
	url: string;
}

/** Parsed and validated content of `facet.config.json`. */
export interface FacetConfig {
	/** The app slug, for example `bfr-plans`. */
	app: string;
	/** The build folder to upload, relative to the project root. */
	outDir: string;
	/** Whether the deployment serves as a single-page app. Defaults to true. */
	spa: boolean;
	/** Named instances, for example `{ "staging": { "url": "..." } }`. */
	targets: Record<string, TargetConfig>;
	/** The target used when no `--target` flag is passed. */
	defaultTarget?: string;
}

/** A target picked for one run, with the name that selected it. */
export interface ResolvedTarget {
	name: string;
	url: string;
}

/** Raised when the config file is missing, invalid, or names an unknown target. */
export class ConfigError extends Error {
	constructor(message: string) {
		super(message);
		this.name = 'ConfigError';
	}
}

export const CONFIG_FILE = 'facet.config.json';

export function configPath(root: string): string {
	return path.join(root, CONFIG_FILE);
}

/**
 * Loads and validates `facet.config.json` from the project root.
 * Every failure raises a `ConfigError` with a message the user can act on.
 */
export function loadConfig(root: string): FacetConfig {
	const file = configPath(root);

	let raw: string;
	try {
		raw = readFileSync(file, 'utf8');
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
			throw new ConfigError(
				`No ${CONFIG_FILE} in ${root}. Run "pnpx @facetapp/cli init" to create one.`
			);
		}
		throw new ConfigError(`Cannot read ${file}: ${errorMessage(error)}`);
	}

	let data: unknown;
	try {
		data = JSON.parse(raw);
	} catch (error) {
		throw new ConfigError(`${file} is not valid JSON: ${errorMessage(error)}`);
	}

	return parseConfig(data, file);
}

/**
 * Picks the target for one run: an explicit name wins, then `defaultTarget`.
 * With no selection the error lists the available target names.
 */
export function resolveTarget(config: FacetConfig, targetName?: string): ResolvedTarget {
	const name = targetName ?? config.defaultTarget;
	const names = Object.keys(config.targets);

	if (name === undefined) {
		if (names.length === 0) {
			throw new ConfigError(
				`No target selected and ${CONFIG_FILE} defines no targets. ` +
					`Add a "targets" entry with the instance URL.`
			);
		}
		throw new ConfigError(
			`No target selected. Pass --target <name> or set "defaultTarget" in ${CONFIG_FILE}. ` +
				`Available targets: ${names.join(', ')}.`
		);
	}

	const target = config.targets[name];
	if (target === undefined) {
		const source = targetName === undefined ? 'defaultTarget' : 'target';
		const available =
			names.length === 0
				? `${CONFIG_FILE} defines no targets`
				: `Available targets: ${names.join(', ')}`;
		throw new ConfigError(`Unknown ${source} "${name}". ${available}.`);
	}

	return { name, url: target.url };
}

function parseConfig(data: unknown, file: string): FacetConfig {
	if (typeof data !== 'object' || data === null || Array.isArray(data)) {
		throw new ConfigError(`${file} must hold a JSON object.`);
	}
	const doc = data as Record<string, unknown>;

	const app = requireString(doc, 'app', file, `Set "app" to the app slug.`);
	const outDir = requireString(doc, 'outDir', file, `Set "outDir" to the build folder.`);

	const spa = doc['spa'] === undefined ? true : doc['spa'];
	if (typeof spa !== 'boolean') {
		throw new ConfigError(`${file} field "spa" must be true or false.`);
	}

	const targets: Record<string, TargetConfig> = {};
	const rawTargets = doc['targets'];
	if (rawTargets !== undefined) {
		if (typeof rawTargets !== 'object' || rawTargets === null || Array.isArray(rawTargets)) {
			throw new ConfigError(`${file} field "targets" must be an object of named targets.`);
		}
		for (const [name, value] of Object.entries(rawTargets)) {
			if (typeof value !== 'object' || value === null || Array.isArray(value)) {
				throw new ConfigError(`${file} target "${name}" must be an object with a "url" field.`);
			}
			targets[name] = {
				url: requireString(
					value as Record<string, unknown>,
					'url',
					file,
					`Target "${name}" needs an instance URL.`
				)
			};
		}
	}

	const defaultTarget = doc['defaultTarget'];
	if (defaultTarget !== undefined && (typeof defaultTarget !== 'string' || defaultTarget === '')) {
		throw new ConfigError(`${file} field "defaultTarget" must be a non-empty string.`);
	}

	return { app, outDir, spa, targets, defaultTarget };
}

function requireString(
	doc: Record<string, unknown>,
	field: string,
	file: string,
	hint: string
): string {
	const value = doc[field];
	if (typeof value !== 'string' || value === '') {
		throw new ConfigError(`${file} has no "${field}" value. ${hint}`);
	}
	return value;
}
