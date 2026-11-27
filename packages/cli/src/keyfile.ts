// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { chmodSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { errorMessage } from './util.js';

/**
 * One stored API key, as `connect` wrote it. The key is a user-owned
 * `fct_` token pinned to one account and one role — never an app-owned key.
 */
export interface StoredKey {
	/** The raw bearer token, `fct_` followed by 26 characters. */
	key: string;
	/** The key's row id on the instance. */
	id: string;
	/** The display prefix the instance keeps — enough to recognize the key. */
	display_prefix: string;
	/** The qualified role id the key is pinned to, for example `iam.Roles.editor`. */
	role: string;
	/** RFC-3339 UTC instant after which the key stops working, when set. */
	expires_at?: string;
}

/** Parsed and validated content of `.facet.local.json`. */
export interface LocalConfig {
	/** API keys keyed by instance URL. */
	apiKeys: Record<string, StoredKey>;
}

/** Raised when the local key file is malformed. */
export class LocalConfigError extends Error {
	constructor(message: string) {
		super(message);
		this.name = 'LocalConfigError';
	}
}

/**
 * The per-folder key file. It sits next to `facet.config.json` so each
 * project carries its own key — several Facet setups can live side by side,
 * each in its own folder. The file is gitignored; it holds a secret.
 */
export const LOCAL_CONFIG_FILE = '.facet.local.json';

export function localConfigPath(root: string): string {
	return path.join(root, LOCAL_CONFIG_FILE);
}

/** Keys are keyed by instance URL, normalizing trailing slashes. */
function instanceKey(instanceUrl: string): string {
	return instanceUrl.replace(/\/+$/, '');
}

/** Reads the key file. A missing file reads as empty; a malformed one throws. */
export function readLocalConfig(root: string): LocalConfig {
	const file = localConfigPath(root);

	let raw: string;
	try {
		raw = readFileSync(file, 'utf8');
	} catch (error) {
		if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
			return { apiKeys: {} };
		}
		throw new LocalConfigError(`Cannot read ${file}: ${errorMessage(error)}`);
	}

	let data: unknown;
	try {
		data = JSON.parse(raw);
	} catch (error) {
		throw new LocalConfigError(`${file} is not valid JSON: ${errorMessage(error)}`);
	}
	if (typeof data !== 'object' || data === null || Array.isArray(data)) {
		throw new LocalConfigError(`${file} must hold a JSON object.`);
	}

	const doc = data as Record<string, unknown>;
	const rawKeys = doc['apiKeys'];
	const apiKeys: Record<string, StoredKey> = {};
	if (rawKeys !== undefined) {
		if (typeof rawKeys !== 'object' || rawKeys === null || Array.isArray(rawKeys)) {
			throw new LocalConfigError(
				`${file} field "apiKeys" must be an object keyed by instance URL.`
			);
		}
		for (const [instance, value] of Object.entries(rawKeys)) {
			apiKeys[instance] = parseStoredKey(value, file, instance);
		}
	}
	return { apiKeys };
}

/** Returns the stored key for one instance, or undefined when none exists. */
export function readStoredKey(root: string, instanceUrl: string): StoredKey | undefined {
	return readLocalConfig(root).apiKeys[instanceKey(instanceUrl)];
}

/** Writes one key for one instance, keeping every other stored key intact. */
export function writeStoredKey(root: string, instanceUrl: string, stored: StoredKey): void {
	const file = localConfigPath(root);
	const config = readLocalConfig(root);
	config.apiKeys[instanceKey(instanceUrl)] = stored;

	// `mode` applies only at file creation; chmod after write keeps the file
	// at 600 even when it already existed with wider access.
	writeFileSync(file, `${JSON.stringify(config, null, '\t')}\n`, { mode: 0o600 });
	chmodSync(file, 0o600);
}

function parseStoredKey(value: unknown, file: string, instance: string): StoredKey {
	if (typeof value !== 'object' || value === null || Array.isArray(value)) {
		throw new LocalConfigError(`${file} key for "${instance}" must be an object.`);
	}
	const doc = value as Record<string, unknown>;
	const key = requireString(doc, 'key', file, instance);
	const id = requireString(doc, 'id', file, instance);
	const displayPrefix = requireString(doc, 'display_prefix', file, instance);
	const role = requireString(doc, 'role', file, instance);

	const expiresAt = doc['expires_at'];
	if (expiresAt !== undefined && expiresAt !== null && typeof expiresAt !== 'string') {
		throw new LocalConfigError(
			`${file} key for "${instance}" field "expires_at" must be a string.`
		);
	}

	return {
		key,
		id,
		display_prefix: displayPrefix,
		role,
		...(typeof expiresAt === 'string' ? { expires_at: expiresAt } : {})
	};
}

function requireString(
	doc: Record<string, unknown>,
	field: string,
	file: string,
	instance: string
): string {
	const value = doc[field];
	if (typeof value !== 'string' || value === '') {
		throw new LocalConfigError(`${file} key for "${instance}" has no "${field}" value.`);
	}
	return value;
}
