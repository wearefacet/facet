// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { TokenProvider } from './auth/provider.js';
import type { CacheStore } from './cache.js';
import { requestBytes, requestJson } from './http.js';
import { filePartName } from './multipart.js';

/** The prefix of an inline artifact link in a longtext field. */
export const ARTIFACT_URN_PREFIX = 'urn:facet:artifact:';

/** Shape of a standalone upload. The same shape the frontend helper uses. */
export interface ArtifactUploadResult {
	id: string;
	filename: string;
}

/** Metadata of one artifact, plus the freshly minted grant URL of `show`. */
export interface ArtifactMeta {
	id: string;
	filename: string;
	/** Sniffed from the bytes server-side, never from the client header. */
	mime_type: string;
	/** Byte size. */
	size: number;
	sha256: string;
	/** Signed serve URL; rotates on every fetch of the metadata. */
	url: string;
	/** When the signed URL expires, RFC-3339. */
	expires_at: string | null;
}

/** One minted grant: an ephemeral or a permanent signed URL. */
export interface ArtifactGrant {
	grant_id: string;
	artifact_id: string;
	url: string;
	/** When an ephemeral grant expires, RFC-3339. */
	expires_at?: string | null;
	/** True on a permanent grant from `publish`. */
	permanent?: boolean;
}

/** Options for `upload`. */
export interface UploadOptions {
	/** The stored file name. Defaults to the file's own name. */
	filename?: string;
}

/** Options for `publish`. */
export interface PublishOptions {
	/**
	 * The provenance row the permanent grant binds to. The server requires
	 * it; `show` and the document surfaces expose owner rows.
	 */
	ownerId: string;
}

/** Options for `downloadUrl`. */
export interface DownloadUrlOptions {
	/**
	 * An app id annotated on the URL. With a matching app `Origin`, the
	 * backend authorizes the read through the app's grant ceiling.
	 */
	appId?: string;
}

/** Upload, grant, and download artifacts. Created as `facet.artifacts`. */
export interface ArtifactHandle {
	/**
	 * Uploads one file to the standalone route. The artifact becomes
	 * readable when its id lands in a `file` field or a longtext link;
	 * uploading alone grants nothing to others.
	 */
	upload(file: File | Blob, options?: UploadOptions): Promise<ArtifactUploadResult>;

	/** Uploads and returns the `urn:facet:artifact:<id>` string for longtexts. */
	uploadAsUrn(file: File | Blob, options?: UploadOptions): Promise<string>;

	/** Reads the metadata of one artifact, with a fresh grant URL. */
	show(id: string): Promise<ArtifactMeta>;

	/**
	 * Mints an ephemeral signed URL for readers outside Facet. The server
	 * derives the TTL from the artifact's media type — no client-side TTL.
	 * Authenticated readers need no grant.
	 */
	grant(id: string): Promise<ArtifactGrant>;

	/**
	 * Mints a permanent public grant — the only channel to readers with no
	 * account and no app. Needs the `publish_artifact` action on an owner
	 * document; a denial surfaces as a typed `403`.
	 */
	publish(id: string, options: PublishOptions): Promise<ArtifactGrant>;

	/** Revokes one grant. */
	revoke(gid: string): Promise<void>;

	/**
	 * Downloads the bytes through the gateway, following the `302` to the
	 * signed serve URL.
	 */
	download(id: string): Promise<ArrayBuffer>;

	/**
	 * Builds the gateway URL for `<a href>` and `<img src>` use — no fetch.
	 * Each request re-enters the gateway and mints a fresh grant.
	 */
	downloadUrl(id: string, options?: DownloadUrlOptions): string;
}

/** Shared credentials, fetch, and ETag store for the artifact handle. */
class RestArtifacts implements ArtifactHandle {
	constructor(
		private readonly baseUrl: string,
		private readonly auth: TokenProvider | undefined,
		private readonly fetchImpl: typeof fetch | undefined,
		private readonly cache: CacheStore | undefined
	) {}

	private request<T>(
		path: string,
		options: { method?: 'GET' | 'POST' | 'DELETE'; json?: unknown; form?: FormData } = {}
	): Promise<T> {
		return requestJson(this.baseUrl, path, {
			method: options.method,
			json: options.json,
			form: options.form,
			auth: this.auth,
			fetchImpl: this.fetchImpl,
			cache: this.cache
		});
	}

	upload(file: File | Blob, options: UploadOptions = {}): Promise<ArtifactUploadResult> {
		const form = new FormData();
		form.append('file', file, filePartName(file, options.filename));
		// The route answers the full metadata; the handle projects the upload
		// result to the `{ id, filename }` shape. `show` returns the rest.
		return this.request<{ id: string; filename: string }>('/Api/core/artifacts', {
			method: 'POST',
			form
		}).then((result) => ({ id: result.id, filename: result.filename }));
	}

	async uploadAsUrn(file: File | Blob, options: UploadOptions = {}): Promise<string> {
		const result = await this.upload(file, options);
		return `${ARTIFACT_URN_PREFIX}${result.id}`;
	}

	show(id: string): Promise<ArtifactMeta> {
		return this.request(`/Api/core/artifacts/${encodeURIComponent(id)}`);
	}

	grant(id: string): Promise<ArtifactGrant> {
		return this.request(`/Api/core/artifacts/${encodeURIComponent(id)}/grant`, {
			method: 'POST'
		});
	}

	publish(id: string, options: PublishOptions): Promise<ArtifactGrant> {
		return this.request(`/Api/core/artifacts/${encodeURIComponent(id)}/publish`, {
			method: 'POST',
			json: { owner_id: options.ownerId }
		});
	}

	revoke(gid: string): Promise<void> {
		return this.request(`/Api/core/artifacts/grants/${encodeURIComponent(gid)}`, {
			method: 'DELETE'
		});
	}

	download(id: string): Promise<ArrayBuffer> {
		return requestBytes(this.baseUrl, `/Api/core/artifacts/${encodeURIComponent(id)}/download`, {
			auth: this.auth,
			fetchImpl: this.fetchImpl
		});
	}

	downloadUrl(id: string, options: DownloadUrlOptions = {}): string {
		const url = new URL(`/Api/core/artifacts/${encodeURIComponent(id)}/download`, this.baseUrl);
		if (options.appId !== undefined) {
			url.searchParams.set('app', options.appId);
		}
		return url.toString();
	}
}

/** Creates the artifact handle of one client. */
export function createArtifactHandle(
	baseUrl: string,
	auth: TokenProvider | undefined,
	fetchImpl: typeof fetch | undefined,
	cache: CacheStore | undefined
): ArtifactHandle {
	return new RestArtifacts(baseUrl, auth, fetchImpl, cache);
}
