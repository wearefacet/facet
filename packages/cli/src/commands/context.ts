// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { createApi, type FacetApi } from '../api.js';
import { loadConfig, resolveTarget, type FacetConfig, type ResolvedTarget } from '../config.js';
import { createInterface } from 'node:readline/promises';

/** Everything a command needs to talk to one Facet instance. */
export interface CommandContext {
	config: FacetConfig;
	/** The target this run points at, with the name that selected it. */
	target: ResolvedTarget;
	/** The instance URL, without the target wrapper. */
	instanceUrl: string;
	api: FacetApi;
}

/**
 * Loads the project config and picks the target: `--target <name>` first,
 * then `defaultTarget`. Raises `ConfigError` for every failure the user
 * can fix.
 */
export function loadContext(root: string, targetName?: string): CommandContext {
	const config = loadConfig(root);
	const target = resolveTarget(config, targetName);
	return {
		config,
		target,
		instanceUrl: target.url,
		api: createApi(target.url)
	};
}

/** Asks the user one question and returns the trimmed answer. */
export type PromptFn = (question: string, fallback?: string) => Promise<string>;

/** Asks one question through readline, pre-filled with the fallback. */
export function prompt(question: string, fallback?: string): Promise<string> {
	const suffix = fallback !== undefined && fallback !== '' ? ` [${fallback}]` : '';
	const readline = createInterface({ input: process.stdin, output: process.stdout });
	return readline
		.question(`${question}${suffix}: `)
		.then((answer) => answer.trim() || (fallback ?? ''))
		.finally(() => readline.close());
}

/** Asks a yes/no question. Anything but `y`/`yes` means no. */
export async function confirm(question: string, promptFn: PromptFn = prompt): Promise<boolean> {
	const answer = (await promptFn(`${question} (y/N)`)).toLowerCase();
	return answer === 'y' || answer === 'yes';
}

/** Asks a yes/no question that takes yes on a bare Enter. */
export async function confirmDefaultYes(
	question: string,
	promptFn: PromptFn = prompt
): Promise<boolean> {
	const answer = (await promptFn(`${question} (Y/n)`)).toLowerCase();
	return answer !== 'n' && answer !== 'no';
}
