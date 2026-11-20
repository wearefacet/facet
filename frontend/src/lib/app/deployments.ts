// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

// Thin client for app deployments (Part C — Facet serves app builds).
//
// Backend:
//   POST /Api/app/:id/deploy                     multipart build upload
//                                                (`src/app/deploy.cr`)
//   GET  /Api/app/Deployment                     deployment documents via the
//                                                standard Document API
//   PATCH /Api/app/App/:id                       activate = set
//                                                `active_deployment`
//
// Deployments are ordinary event-sourced documents, so the read and the
// activation route through the DataSource (token refresh + cache
// invalidation for free). Only the multipart upload needs its own request:
// the deploy route owns the `$content` + `files[<i>].file` wire format and
// the generic multipart client stays a follow-up.

import { apiFetch } from '$lib/session.svelte';
import { DocumentDataSource } from '$lib/datasource/DocumentDataSource';
import { DataSourceError } from '$lib/datasource/types';
import type { ListItem } from '$lib/datasource/types';
import type { AppContent, DeploymentContent } from '$lib/app/appTypes';

type FetchFn = typeof fetch;

/** A file picked for upload plus the path it will take in the deployment. */
export interface DeployFile {
	/** Path relative to the app root, e.g. `index.html` (already validated). */
	path: string;
	/** The picked file. */
	file: File;
}

/** Response of `POST /Api/app/:id/deploy`. */
export interface DeployResult {
	id: string;
	revision: number | null;
	activated: boolean;
	files: number;
}

/** The deployment document referenced by an app's `active_deployment` field. */
export type DeploymentRow = ListItem<DeploymentContent>;

/** Strip the `{domain}.{Doctype}.` prefix from a qualified reference value. */
export function bareReferenceId(qualified: string, prefix: string): string {
	return qualified.startsWith(prefix) ? qualified.slice(prefix.length) : qualified;
}

/**
 * List the app's deployments, newest revision first. `appId` is the bare
 * projection id; the stored `app_id` reference value is qualified, so the
 * filter compares against the qualified form.
 */
export async function listDeployments(appId: string, fetchFn?: FetchFn): Promise<DeploymentRow[]> {
	const deployments = new DocumentDataSource<DeploymentContent>(
		'app',
		'Deployment',
		undefined,
		fetchFn
	);
	const { data } = await deployments.list({ filters: { app_id__eq: `app.App.${appId}` } });
	return [...data].sort((a, b) => (b.data.revision ?? 0) - (a.data.revision ?? 0));
}

/**
 * Activate a deployment (or roll back to an older one): point the app's
 * `active_deployment` at the chosen document. Ordinary PATCH on `app.App` —
 * the dispatcher picks the change up on the next request via the host cache.
 */
export async function activateDeployment(
	appId: string,
	deploymentId: string,
	fetchFn?: FetchFn
): Promise<void> {
	const apps = new DocumentDataSource<AppContent>('app', 'App', undefined, fetchFn);
	await apps.doc(appId).update({ active_deployment: `app.Deployment.${deploymentId}` });
}

/**
 * Upload a build and (optionally) activate it in the same request. The
 * wire format is the deploy route's: a `$content` JSON part plus one part
 * per file named `files[<i>].file`. The caller's `file` values are stripped
 * server-side — artifact ids come only from this request's parts.
 *
 * No `Content-Type` header is set here: the browser supplies the multipart
 * boundary. The `X-Requested-With` header is required — the operator-session
 * path is CSRF-checked server-side.
 */
export async function uploadDeployment(
	appId: string,
	input: { files: DeployFile[]; note?: string; spa: boolean; activate: boolean },
	fetchFn?: FetchFn
): Promise<DeployResult> {
	const content = {
		note: input.note ?? '',
		spa: input.spa,
		activate: input.activate,
		files: input.files.map((entry) => ({ path: entry.path }))
	};

	const form = new FormData();
	form.append('$content', JSON.stringify(content));
	input.files.forEach((entry, i) => {
		form.append(`files[${i}].file`, entry.file, entry.path);
	});

	const res = await apiFetch(
		`/Api/app/${encodeURIComponent(appId)}/deploy${input.activate ? '?activate=true' : ''}`,
		{
			method: 'POST',
			headers: { 'X-Requested-With': 'XMLHttpRequest' },
			body: form
		},
		{ fetch: fetchFn }
	);

	if (!res.ok) {
		const body = (await res.json().catch(() => ({}))) as {
			error?: string;
			details?: { message: string }[];
		};
		const detail = body.details?.map((d) => d.message).join('; ');
		throw new DataSourceError(
			res.status,
			detail ? `${body.error}: ${detail}` : (body.error ?? `Deploy failed (${res.status})`)
		);
	}
	return (await res.json()) as DeployResult;
}
