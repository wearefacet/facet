// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { existsSync } from 'node:fs';
import { loadContext, prompt, type PromptFn } from './context.js';
import { login as loginFlow } from '../login.js';
import type { StoredSession } from '../auth.js';
import { ConfigError, configPath } from '../config.js';

export interface LoginOptions {
	promptFn?: PromptFn;
	/** Test seam: replaces the interactive OAuth flow. */
	flow?: (input: { instanceUrl: string }) => Promise<StoredSession>;
}

/**
 * Signs in to one instance and stores the session. The instance comes from
 * `--target` or `defaultTarget` when a config exists; without a config the
 * command asks for the URL.
 */
export async function runLogin(
	root: string,
	targetName: string | undefined,
	options: LoginOptions = {}
): Promise<void> {
	const instanceUrl = await resolveInstanceUrl(root, targetName, options.promptFn ?? prompt);
	const session = await (options.flow ?? loginFlow)({ instanceUrl });
	console.log(`Signed in to ${instanceUrl} as account ${session.account} (role ${session.role}).`);
}

async function resolveInstanceUrl(
	root: string,
	targetName: string | undefined,
	ask: PromptFn
): Promise<string> {
	if (existsSync(configPath(root))) {
		const { instanceUrl, target } = loadContext(root, targetName);
		console.log(`Signing in to ${instanceUrl} (target "${target.name}").`);
		return instanceUrl;
	}
	if (targetName !== undefined) {
		throw new ConfigError(`No facet.config.json in ${root}, so no target "${targetName}" exists.`);
	}
	for (;;) {
		const answer = await ask('Instance URL');
		if (answer !== '') {
			return answer;
		}
		console.error(`A value is required.`);
	}
}
