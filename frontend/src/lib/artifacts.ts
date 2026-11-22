// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Artifact helpers for longtext (markdown) editing surfaces.
 *
 * The persisted markdown source references uploaded files inline as
 * `urn:facet:artifact:<id>` (see `doc/backend/artifact.md`): the standalone
 * `POST /Api/core/artifacts` route stores the bytes and binds provenance to
 * the uploading account, and `Document::ArtifactRefs` extracts the URNs on
 * save into `artifact_references` rows. The URN is the source of truth; DOM
 * rendering resolves it to the cookie-auth download gateway
 * (`GET /Api/core/artifacts/:id/download`), which mints a fresh grant and
 * 302-redirects to the signed serve URL on every request.
 *
 * Display contract for `urn:facet:artifact:` URNs — resolved inside the
 * Milkdown editor DOM (`Milkdown.svelte`), which renders every markdown
 * surface (preview, readonly, write):
 *
 * - Image position (`![](urn:…)`) loads as an `<img>` through the gateway
 *   (Crepe's `proxyDomURL` / `resolveArtifactUrl`).
 * - Link position (`[label](urn:…)`) renders as a capsule — a small pill
 *   with the link label (the filename when inserted by the editor). In the
 *   editor DOM the URN never becomes an href (Milkdown sanitizes unknown
 *   schemes), so a decoration tags the capsule and, when readonly, a click
 *   delegate opens the download gateway.
 */

import { apiErrorMessage } from '$lib/http.js';
import { artifactMetadataCache } from '$lib/datasource/clientCache.js';
import * as m from '$lib/paraglide/messages';

export const ARTIFACT_URN_PREFIX = 'urn:facet:artifact:';

/** Shape returned by `GET /Api/core/artifacts/:id` (filename + grant URL). */
export interface ArtifactGrant {
	id: string;
	filename: string;
	mime_type?: string;
	size?: number;
	sha256?: string;
	url: string;
	expires_at?: string;
}

/** Shape returned by `POST /Api/core/artifacts` (standalone upload). */
export interface ArtifactUploadResult {
	id: string;
	filename: string;
}

/**
 * Extract the artifact id from an artifact URN. Returns `null` for any
 * other string — including malformed URNs (prefix without an id).
 */
export function parseArtifactUrn(url: string): string | null {
	if (!url.startsWith(ARTIFACT_URN_PREFIX)) return null;
	const id = url.slice(ARTIFACT_URN_PREFIX.length);
	return id.length > 0 ? id : null;
}

/** Build an inline artifact URN from an artifact id. */
export function artifactUrn(id: string): string {
	return `${ARTIFACT_URN_PREFIX}${id}`;
}

/**
 * Cookie-auth download gateway URL for an artifact. The route performs
 * auth + RBAC + grant mint + 302 to the signed serve URL on every request
 * (`doc/backend/artifact.md` → Download gateway) — no client-side grant
 * minting, no signed URL ever cached in the page DOM.
 */
export function artifactDownloadUrl(id: string): string {
	return `/Api/core/artifacts/${id}/download`;
}

/**
 * Resolve a URL for DOM rendering: an artifact URN becomes the download
 * gateway URL; anything else passes through unchanged.
 */
export function resolveArtifactUrl(url: string): string {
	const id = parseArtifactUrn(url);
	return id ? artifactDownloadUrl(id) : url;
}

/**
 * Default artifact metadata fetch: `GET /Api/core/artifacts/:id` via
 * `apiFetch`.
 */
async function fetchArtifactGrant(id: string): Promise<ArtifactGrant> {
	const { apiFetch } = await import('$lib/session.svelte');
	const res = await apiFetch(`/Api/core/artifacts/${id}`);
	if (!res.ok) {
		const body = await res.json().catch(() => ({}) as { error?: string });
		throw new Error((body as { error?: string }).error ?? `Fetch failed (${res.status})`);
	}
	return (await res.json()) as ArtifactGrant;
}

/**
 * Resolve the metadata of one artifact (filename, grant URL). The result is
 * cached for the client-cache TTL and concurrent callers share the in-flight
 * request, so a listing with many `file` cells reads one entry per distinct
 * artifact. A failed fetch is not cached.
 *
 * `fetcher` overrides the default API call (stories pass a synthetic one).
 */
export async function resolveArtifact(
	id: string,
	fetcher?: (id: string) => Promise<ArtifactGrant>
): Promise<ArtifactGrant> {
	const fetch = fetcher ?? fetchArtifactGrant;
	return (await artifactMetadataCache.get(id, () => fetch(id))) as ArtifactGrant;
}

/**
 * Upload a file to the standalone artifact route and return the URN the
 * editor inserts into the markdown. `uploadFile` is the injectable
 * uploader (stories substitute a synthetic one); it defaults to
 * `postArtifact`.
 */
export async function uploadArtifactAsUrn(
	file: File,
	uploadFile?: (file: File) => Promise<ArtifactUploadResult>
): Promise<string> {
	const result = uploadFile ? await uploadFile(file) : await postArtifact(file);
	return `${ARTIFACT_URN_PREFIX}${result.id}`;
}

/**
 * Default upload path: multipart `POST /Api/core/artifacts`. The route
 * responds with the artifact id + metadata.
 */
export async function postArtifact(file: File): Promise<ArtifactUploadResult> {
	const { apiFetch } = await import('$lib/session.svelte');
	const form = new FormData();
	form.append('file', file, file.name);
	const res = await apiFetch('/Api/core/artifacts', {
		method: 'POST',
		body: form
	});
	if (!res.ok) {
		throw await apiErrorMessage(res, m.errors_upload_failed());
	}
	return (await res.json()) as ArtifactUploadResult;
}
