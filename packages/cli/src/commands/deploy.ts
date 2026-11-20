// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import path from 'node:path';
import { loadContext } from './context.js';
import { loadBuildFiles, buildDeployBody } from '../deploy.js';

export interface DeployFlags {
	target?: string;
	note?: string;
	/** Commander sets this false when `--no-activate` is passed. */
	activate?: boolean;
}

/**
 * Builds the URL of a deployed app: the instance URL supplies the scheme and
 * any explicit port, the app record supplies only a bare host.
 */
export function appUrl(instanceUrl: string, host: string): string {
	const url = new URL(instanceUrl);
	const port = url.port === '' ? '' : `:${url.port}`;
	return `${url.protocol.replace(':', '')}://${host}${port}`;
}

/** Uploads the build folder as a new deployment of the configured app. */
export async function runDeploy(root: string, flags: DeployFlags = {}): Promise<void> {
	const { config, instanceUrl, api } = loadContext(root, flags.target);
	const activate = flags.activate !== false;
	const outDir = path.resolve(root, config.outDir);

	console.log(`Deploying "${config.outDir}" to ${instanceUrl} (target of app "${config.app}")…`);

	const appId = await api.resolveAppId(config.app);
	const app = await api.readApp(appId);
	const host = typeof app.data.host === 'string' ? app.data.host : undefined;

	const files = loadBuildFiles(outDir);
	console.log(`Packed ${files.length} file${files.length === 1 ? '' : 's'}.`);

	const body = buildDeployBody({
		note: flags.note,
		spa: config.spa,
		activate,
		files
	});
	const result = await api.deploy(appId, body.body, body.contentType);

	const revision = result.revision ?? '?';
	console.log(
		`Deployed revision ${revision} (${result.files} file${result.files === 1 ? '' : 's'} stored).`
	);
	if (result.activated && host !== undefined) {
		console.log(`Active at ${appUrl(instanceUrl, host)}`);
	} else if (result.activated) {
		console.log(`Activated. The app has no host yet — set one on the app record.`);
	} else {
		console.log(`Left inactive. Activate it later with "facet-cli rollback ${revision}".`);
	}
}
