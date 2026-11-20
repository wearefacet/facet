// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { existsSync, writeFileSync } from 'node:fs';
import { createApi } from '../api.js';
import { readSession } from '../auth.js';
import {
	CONFIG_FILE,
	ConfigError,
	configPath,
	type FacetConfig,
	type TargetConfig
} from '../config.js';
import { errorMessage } from '../util.js';
import { confirm, prompt, type PromptFn } from './context.js';

export interface InitOptions {
	promptFn?: PromptFn;
	/** Creates a missing app without asking for confirmation. */
	yes?: boolean;
	/** App slug; any answer flag makes the run flag-driven. */
	app?: string;
	/** Build folder; defaults to `dist` when omitted. */
	build?: string;
	/** Instance URL; when omitted, no target is written and no app check runs. */
	server?: string;
	/** Reads the piped answers; injected in tests. */
	readStdinFn?: () => Promise<string>;
}

/**
 * Writes `facet.config.json` for this project. Offline safe: with no stored
 * session the config is written and the command stops there. With a stored
 * session for the asked-for instance, the app is read by slug and offered
 * for creation (needs `write` on `app.App`).
 *
 * Answers come from flags (`--app`, `--build`, `--server`), from piped stdin
 * (three lines: app slug, build folder, instance URL), or from interactive
 * prompts. With no flags and non-interactive stdin the command throws
 * `ConfigError` instead of waiting on closed stdin and exiting with no
 * message and no config.
 */
export async function runInit(root: string, options: InitOptions = {}): Promise<void> {
	if (existsSync(configPath(root))) {
		throw new ConfigError(`${CONFIG_FILE} already exists in ${root}. Edit it by hand.`);
	}

	const hasAnswerFlags =
		options.app !== undefined || options.build !== undefined || options.server !== undefined;
	const canPrompt = options.promptFn !== undefined || process.stdin.isTTY === true;
	const interactive = canPrompt && options.yes !== true;

	let app: string;
	let outDir: string;
	let instanceUrl: string;

	if (!hasAnswerFlags && interactive) {
		const ask = options.promptFn ?? prompt;
		app = await requireAnswer(ask, 'App slug');
		outDir = await ask('Build folder', 'dist');
		instanceUrl = await ask('Instance URL (empty to skip)');
	} else if (hasAnswerFlags) {
		app = options.app?.trim() ?? '';
		outDir = options.build?.trim() || 'dist';
		instanceUrl = options.server?.trim() ?? '';
		if (app === '') {
			throw new ConfigError(
				'@facetapp/cli init needs an app slug. Pass --app <slug>, pipe the answers on stdin, or run it in an interactive terminal.'
			);
		}
	} else if (canPrompt) {
		throw new ConfigError(
			'@facetapp/cli init needs answers. Pass --app <slug> (with optional --build <dir> and --server <url>), pipe them on stdin, or run it without --yes in an interactive terminal.'
		);
	} else {
		const [appLine, buildLine, serverLine] = await readStdinLines(options.readStdinFn);
		app = appLine?.trim() ?? '';
		outDir = buildLine?.trim() || 'dist';
		instanceUrl = serverLine?.trim() ?? '';
		if (app === '') {
			throw new ConfigError(
				'@facetapp/cli init needs answers. Pass --app <slug> (with optional --build <dir> and --server <url>), pipe them on stdin, or run it in an interactive terminal.'
			);
		}
	}

	const targets: Record<string, TargetConfig> = {};
	let defaultTarget: string | undefined;
	if (instanceUrl !== '') {
		targets['default'] = { url: instanceUrl };
		defaultTarget = 'default';
	}

	const config: FacetConfig = { app, outDir, spa: true, targets, defaultTarget };
	writeConfig(root, config);
	console.log(`Wrote ${CONFIG_FILE} for app "${app}".`);

	if (instanceUrl === '') {
		console.log(`Add a "targets" entry, then run "pnpx @facetapp/cli login".`);
		return;
	}

	await checkApp(instanceUrl, app, {
		ask: options.promptFn ?? prompt,
		interactive,
		yes: options.yes === true
	});
}

interface CheckAppOptions {
	ask: PromptFn;
	interactive: boolean;
	yes: boolean;
}

/** Reads the app by slug with the stored session; offers to create it. */
async function checkApp(instanceUrl: string, app: string, options: CheckAppOptions): Promise<void> {
	if (readSession(instanceUrl) === undefined) {
		console.log(`No stored session for ${instanceUrl}. Run "pnpx @facetapp/cli login" to sign in.`);
		return;
	}

	const api = createApi(instanceUrl);

	let appId: string | undefined;
	try {
		appId = await api.findAppId(app);
	} catch (error) {
		console.error(`Could not check the app on ${instanceUrl}: ${errorMessage(error)}`);
		return;
	}

	if (appId !== undefined) {
		const found = await api.readApp(appId).catch(() => undefined);
		const name = typeof found?.data.display_name === 'string' ? found.data.display_name : app;
		console.log(`App "${name}" (${appId}) already exists on ${instanceUrl}.`);
		return;
	}

	if (!options.yes) {
		if (!options.interactive) {
			console.log(`No app with slug "${app}" on ${instanceUrl}. Re-run with --yes to create it.`);
			return;
		}
		if (!(await confirm(`No app with slug "${app}" on ${instanceUrl}. Create it?`, options.ask))) {
			console.log(`Left the app uncreated. Run "pnpx @facetapp/cli init" again to retry.`);
			return;
		}
	}

	try {
		const created = await api.createApp(app);
		console.log(
			`Created app "${created.data.display_name ?? app}" (${created.meta.id}) as a draft.`
		);
		console.log(`Activate it in the dashboard before the first deploy.`);
	} catch (error) {
		console.error(`Could not create the app: ${errorMessage(error)}`);
	}
}

/** Reads the piped answers: one per line, in the order app, build, instance URL. */
async function readStdinLines(readStdinFn?: () => Promise<string>): Promise<string[]> {
	const raw = readStdinFn === undefined ? await readAllStdin() : await readStdinFn();
	return raw.split(/\r?\n/);
}

/** Reads stdin to EOF. Only called when stdin is not a terminal. */
function readAllStdin(): Promise<string> {
	return new Promise((resolve, reject) => {
		if (process.stdin.readableEnded || process.stdin.destroyed) {
			resolve('');
			return;
		}

		let data = '';
		const onData = (chunk: string): void => {
			data += chunk;
		};
		const onEnd = (): void => {
			cleanup();
			resolve(data);
		};
		const onError = (error: Error): void => {
			cleanup();
			reject(error);
		};
		const cleanup = (): void => {
			process.stdin.off('data', onData);
			process.stdin.off('end', onEnd);
			process.stdin.off('error', onError);
		};

		process.stdin.setEncoding('utf8');
		process.stdin.on('data', onData);
		process.stdin.on('end', onEnd);
		process.stdin.on('error', onError);
		process.stdin.resume();
	});
}

async function requireAnswer(ask: PromptFn, question: string): Promise<string> {
	for (;;) {
		const answer = await ask(question);
		if (answer !== '') {
			return answer;
		}
		console.error(`A value is required.`);
	}
}

/** Writes the config file; exported for reuse in tests. */
export function writeConfig(root: string, config: FacetConfig): void {
	writeFileSync(configPath(root), `${JSON.stringify(config, null, '\t')}\n`);
}
