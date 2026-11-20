// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { PageLoad } from './$types';
import { listDeployments, type DeploymentRow } from '$lib/app/deployments';

/**
 * Overview tab load — fetches the app's deployment history so the
 * deployment panel can show the current build and offer activate /
 * rollback. A failed read degrades to an empty history (the panel then
 * shows only the CLI notice and the deploy action) rather than blocking
 * the whole overview tab.
 */
export const load: PageLoad = async ({
	parent,
	fetch
}): Promise<{ deployments: DeploymentRow[] }> => {
	const { appId } = await parent();
	try {
		const deployments = await listDeployments(appId, fetch);
		return { deployments };
	} catch {
		return { deployments: [] };
	}
};
