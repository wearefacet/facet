// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { loadContext } from './context.js';

/** Points `active_deployment` at the deployment with the given revision. */
export async function runRollback(
	root: string,
	revisionArg: string,
	targetName?: string
): Promise<void> {
	const { config, api } = loadContext(root, targetName);

	const revision = Number(revisionArg);
	if (!Number.isInteger(revision) || revision < 0) {
		throw new Error(
			`"${revisionArg}" is not a revision number. Run "facet-cli releases" to list them.`
		);
	}

	const appId = await api.resolveAppId(config.app);
	const deployments = await api.listDeployments(appId);
	const target = deployments.data.find((row) => row.data.revision === revision);

	if (target === undefined) {
		const known = deployments.data
			.map((row) => row.data.revision)
			.filter((value) => value !== undefined)
			.join(', ');
		throw new Error(
			known === ''
				? `No deployment with revision ${revision} — the app has no deployments.`
				: `No deployment with revision ${revision}. Known revisions: ${known}.`
		);
	}

	// The write side stores the reference qualified; the read side (the
	// marker comparison) normalizes back to the bare id (releases.ts).
	await api.setActiveDeployment(appId, `app.Deployment.${target.meta.id}`);
	console.log(`Revision ${revision} (${target.meta.id}) is now the active deployment.`);
}
