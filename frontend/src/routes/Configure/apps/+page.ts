// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { PageLoad } from './$types';
import { DocumentDataSource } from '$lib/datasource/DocumentDataSource';
import { bareReferenceId } from '$lib/app/deployments';
import type { AppContent, DeploymentContent } from '$lib/app/appTypes';

/**
 * Apps list load — fetches every `app.App` document so the list can
 * show drafts, active, and disabled apps in one collection. The three
 * badge states share the same row pattern; status filtering is
 * client-side.
 *
 * A second read collects the highest deployed revision per app so managed
 * apps can show a revision badge. It degrades silently: when the
 * `app.Deployment` doctype is unreachable the map stays empty and the
 * list renders without badges.
 */
export const load: PageLoad = async ({ fetch }) => {
	const apps = new DocumentDataSource<AppContent>('app', 'App', undefined, fetch);
	const { data } = await apps.list({});

	const revisions = new Map<string, number>();
	try {
		const deployments = new DocumentDataSource<DeploymentContent>(
			'app',
			'Deployment',
			undefined,
			fetch
		);
		const { data: rows } = await deployments.list({});
		for (const row of rows) {
			const ref = row.data.app_id;
			if (!ref) continue;
			const appId = bareReferenceId(ref, 'app.App.');
			const revision = row.data.revision ?? 0;
			revisions.set(appId, Math.max(revisions.get(appId) ?? 0, revision));
		}
	} catch {
		// Deployment reads are optional decoration — never block the list.
	}

	return { apps: data, revisions };
};
