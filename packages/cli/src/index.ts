#!/usr/bin/env node
// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { Command } from 'commander';
import { createRequire } from 'node:module';
import { pathToFileURL } from 'node:url';
import path from 'node:path';
import { errorMessage } from './util.js';
import { runInit, type InitOptions } from './commands/init.js';
import { runLogin } from './commands/login.js';
import { runLogout } from './commands/logout.js';
import { runWhoami } from './commands/whoami.js';
import { runDeploy } from './commands/deploy.js';
import { runReleases } from './commands/releases.js';
import { runRollback } from './commands/rollback.js';

const require = createRequire(import.meta.url);
const { version } = require('../package.json') as { version: string };

/** Options every command accepts for picking the instance. */
interface TargetOptions {
	target?: string;
}

/**
 * One error boundary for every command: a failure prints to stderr and sets
 * a failing exit code, so scripts never read the run as a success.
 */
function action<Args extends unknown[]>(
	run: (...args: Args) => Promise<void>
): (...args: Args) => Promise<void> {
	return async (...args: Args) => {
		try {
			await run(...args);
		} catch (error) {
			console.error(`error: ${errorMessage(error)}`);
			process.exitCode = 1;
		}
	};
}

export function createProgram(): Command {
	const program = new Command();

	program.name('facet-cli').description('Command-line interface for Facet.').version(version);

	program
		.command('init')
		.description('Write a facet.config.json file for this project.')
		.option('--yes', 'Create the app without asking for confirmation.')
		.option('--app <slug>', 'App slug to write to the config.')
		.option('--build <dir>', 'Build folder to upload (default: dist).')
		.option('--server <url>', 'Facet instance URL to add as the default target.')
		.action(action((opts: InitOptions) => runInit(process.cwd(), opts)));

	program
		.command('login')
		.description('Sign in to a Facet instance and store the session.')
		.option('--target <name>', 'Named target from facet.config.json to sign in to.')
		.action(action((opts: TargetOptions) => runLogin(process.cwd(), opts.target)));

	program
		.command('logout')
		.description('Remove the stored session for a Facet instance.')
		.option('--target <name>', 'Named target from facet.config.json to sign out of.')
		.action(action((opts: TargetOptions) => runLogout(process.cwd(), opts.target)));

	program
		.command('whoami')
		.description('Show the stored account, role, instance, and active revision.')
		.option('--target <name>', 'Named target from facet.config.json to ask.')
		.action(action((opts: TargetOptions) => runWhoami(process.cwd(), opts.target)));

	program
		.command('deploy')
		.description('Upload the build folder as a new deployment of the app.')
		.option('--target <name>', 'Named target from facet.config.json to deploy to.')
		.option('--note <text>', 'Short note to attach to the new deployment.')
		.option('--no-activate', 'Keep the new deployment inactive after the upload.')
		.action(
			action((opts: TargetOptions & { note?: string; activate?: boolean }) =>
				runDeploy(process.cwd(), opts)
			)
		);

	program
		.command('releases')
		.description('List the deployments of the app, newest first.')
		.option('--target <name>', 'Named target from facet.config.json to ask.')
		.action(action((opts: TargetOptions) => runReleases(process.cwd(), opts.target)));

	program
		.command('rollback <revision>')
		.description('Set an older revision as the active deployment.')
		.option('--target <name>', 'Named target from facet.config.json to ask.')
		.action(
			action((revision: string, opts: TargetOptions) =>
				runRollback(process.cwd(), revision, opts.target)
			)
		);

	return program;
}

// Run only when executed directly, so test files can import createProgram
// without the module parsing the test runner arguments.
const entry = process.argv[1] ? pathToFileURL(path.resolve(process.argv[1])).href : null;
if (entry === import.meta.url) {
	createProgram().parse(process.argv);
}
