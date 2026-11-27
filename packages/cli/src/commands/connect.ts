// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { existsSync } from 'node:fs';
import { createApi } from '../api.js';
import { login as loginFlow } from '../login.js';
import type { StoredSession } from '../auth.js';
import { ConfigError, configPath } from '../config.js';
import { writeStoredKey, type StoredKey } from '../keyfile.js';
import { confirm, loadContext, prompt, type PromptFn } from './context.js';

/** Name given to every key the CLI issues, so the account's key list reads clearly. */
export const API_KEY_NAME = 'facet-cli';

export interface ConnectOptions {
	promptFn?: PromptFn;
	/** Test seam: replaces the interactive OAuth flow. */
	login?: (input: { instanceUrl: string }) => Promise<StoredSession>;
	/** Test seam: replaces the API client factory. */
	apiFactory?: typeof createApi;
}

/**
 * Signs in to one instance and, on request, issues a user-owned API key
 * pinned to the signed-in account and its active role. The key lands in
 * `.facet.local.json` next to `facet.config.json` — per folder, so several
 * Facet setups can live side by side. The raw token prints once; only its
 * display prefix stays visible.
 *
 * A key is refused (`422`) when the role is not assigned to the account or
 * its `connectivity` excludes the `api` channel. The instance's message
 * carries the remedy; the command prints it and exits failing.
 */
export async function runConnect(
	root: string,
	targetName?: string,
	options: ConnectOptions = {}
): Promise<void> {
	const instanceUrl = await resolveInstanceUrl(root, targetName, options.promptFn ?? prompt);

	const session = await (options.login ?? loginFlow)({ instanceUrl });
	console.log(`Signed in to ${instanceUrl} as account ${session.account} (role ${session.role}).`);

	if (!(await confirm('Store an API key for this project?', options.promptFn ?? prompt))) {
		console.log('Left no API key. Run "facet-cli apikey" after "facet-cli connect" to issue one.');
		return;
	}

	const api = (options.apiFactory ?? createApi)(instanceUrl);
	const me = await api.me();
	const created = await api.createApiKey(API_KEY_NAME, me.active_role);

	const stored: StoredKey = {
		key: created.key,
		id: created.id,
		display_prefix: created.display_prefix,
		role: me.active_role,
		...(created.expires_at !== null ? { expires_at: created.expires_at } : {})
	};
	writeStoredKey(root, instanceUrl, stored);

	console.log(`Issued API key ${created.display_prefix} (role ${me.active_role}).`);
	console.log(
		`Stored it in .facet.local.json. Use it with: Authorization: Bearer $(facet-cli apikey)`
	);
}

/** Resolves the instance URL: the configured target first, then a prompt. */
async function resolveInstanceUrl(
	root: string,
	targetName: string | undefined,
	ask: PromptFn
): Promise<string> {
	if (existsSync(configPath(root))) {
		const { instanceUrl } = loadContext(root, targetName);
		return instanceUrl;
	}
	if (targetName !== undefined) {
		throw new ConfigError(`No facet.config.json in ${root}, so no target "${targetName}" exists.`);
	}
	for (;;) {
		const answer = await ask('Facet URL');
		if (answer !== '') {
			return answer;
		}
		console.error('A value is required.');
	}
}
