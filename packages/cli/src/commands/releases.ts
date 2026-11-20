// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { loadContext } from './context.js';
import { bareDocId } from '../util.js';

/** Lists the app's deployments, newest revision first, marking the active one. */
export async function runReleases(root: string, targetName?: string): Promise<void> {
	const { config, api } = loadContext(root, targetName);

	const appId = await api.resolveAppId(config.app);
	const [app, deployments] = await Promise.all([api.readApp(appId), api.listDeployments(appId)]);
	// The stored reference is qualified ("app.Deployment.<id>"); the list
	// rows carry the bare id, so normalize before comparing.
	const activeId =
		typeof app.data.active_deployment === 'string'
			? bareDocId(app.data.active_deployment)
			: undefined;

	if (deployments.data.length === 0) {
		console.log(`No deployments for "${config.app}" yet. Run "facet-cli deploy" first.`);
		return;
	}

	const width = Math.max(...deployments.data.map((row) => String(row.data.revision ?? '?').length));
	for (const row of deployments.data) {
		const marker = row.meta.id === activeId ? '*' : ' ';
		const revision = String(row.data.revision ?? '?').padStart(width);
		const rest = [
			typeof row.data.note === 'string' ? row.data.note : '',
			typeof row.meta.created_at === 'string' ? row.meta.created_at : ''
		].filter((part) => part !== '');
		console.log(`${marker} ${revision}  ${row.meta.id}  ${rest.join('  ')}`.trimEnd());
	}
	console.log();
	console.log(`(* marks the active deployment)`);
}
