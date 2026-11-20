// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { loadContext } from './context.js';
import { bareDocId } from '../util.js';

/** One `iam.Account` profile, as `/Api/iam/me` answers it. */
interface MeResponse {
	account: { id: string; display_name?: string; email?: string };
	active_role: string;
}

/** Shows who the stored session belongs to, plus the app's active revision. */
export async function runWhoami(root: string, targetName?: string): Promise<void> {
	const { config, instanceUrl, api } = loadContext(root, targetName);

	const me = await api.request<MeResponse>('/Api/iam/me');
	const account = me.account;
	const who =
		typeof account.email === 'string' && account.email !== '' ? account.email : account.id;
	console.log(`instance: ${instanceUrl}`);
	console.log(`account:  ${who}`);
	console.log(`role:     ${me.active_role}`);

	const appId = await api.resolveAppId(config.app);
	const app = await api.readApp(appId);

	const activeId =
		typeof app.data.active_deployment === 'string'
			? bareDocId(app.data.active_deployment)
			: undefined;
	if (typeof activeId !== 'string' || activeId === '') {
		console.log(`app:      ${config.app} (no deployment yet)`);
		return;
	}

	const deployments = await api.listDeployments(appId);
	const active = deployments.data.find((row) => row.meta.id === activeId);
	const revision = active?.data.revision;
	console.log(`app:      ${config.app} — revision ${revision ?? '?'} active (${activeId})`);
}
