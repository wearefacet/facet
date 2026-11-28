// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { loadContext } from './context.js';
import { LocalConfigError, LOCAL_CONFIG_FILE, readStoredKey } from '../keyfile.js';

/** Raised when no key is stored for the configured instance. */
export class NoStoredKeyError extends Error {
	constructor(instanceUrl: string) {
		super(
			`No API key stored for ${instanceUrl} in ${LOCAL_CONFIG_FILE}. ` +
				`Run "facet-cli connect" and choose to store a key.`
		);
		this.name = 'NoStoredKeyError';
	}
}

/**
 * Prints the stored API key for the configured target to stdout, so a shell
 * can inline it: `Authorization: Bearer $(facet-cli apikey)`. Prints nothing
 * but the raw token — no banner — so a command substitution stays clean.
 * Fails when no key is stored; the error goes to stderr.
 */
export async function runApikey(root: string, targetName?: string): Promise<void> {
	const { instanceUrl } = loadContext(root, targetName);
	const stored = readStoredKey(root, instanceUrl);
	if (stored === undefined) {
		throw new NoStoredKeyError(instanceUrl);
	}
	if (stored.expires_at !== undefined) {
		const expires = Date.parse(stored.expires_at);
		if (!Number.isNaN(expires) && expires <= Date.now()) {
			throw new LocalConfigError(
				`The stored API key for ${instanceUrl} expired at ${stored.expires_at}. ` +
					`Run "facet-cli connect" again to issue a fresh one.`
			);
		}
	}
	process.stdout.write(`${stored.key}\n`);
}
