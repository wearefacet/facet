<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { Download } from '@lucide/svelte';
	import { resolveArtifact, type ArtifactGrant } from '$lib/artifacts.js';
	import '../shared.css';

	/**
	 * Read-only render of a `file`-typed doctype field value.
	 *
	 * The stored value is the bare artifact id (a 26-char ULID). The filename
	 * is resolved from the backend's artifact metadata
	 * (`GET /Api/core/artifacts/:id`) on mount so the label reads as a human
	 * filename rather than an opaque ULID. The lookup goes through
	 * `resolveArtifact`, which caches the metadata per artifact id — a table
	 * cell and the show page of the same document share one fetch. The
	 * download link is a plain `<a href="/Api/core/artifacts/:id/download">` —
	 * the gateway route mints a fresh ephemeral grant and 302-redirects to the
	 * signed serve URL on each click. No JS on click: no stale cached URL, no
	 * client-side grant mint, and the link works for shared / app-embedded
	 * contexts (`?app=APP_ID` may be appended by integrators;
	 * `doc/backend/artifact.md` → Download gateway).
	 *
	 * Falls back to displaying the bare id as the label when the filename fetch
	 * fails — the id is still the canonical stored value, and the link still
	 * resolves a fresh grant server-side.
	 */
	let {
		artifactId,
		fetchArtifact
	}: {
		/** The bare artifact id stored in the document content. */
		artifactId: string;
		/**
		 * Injectable fetch — receives the artifact id and returns the grant
		 * metadata (used only for the on-mount filename label resolve).
		 * Defaults to `GET /Api/core/artifacts/:id` via `apiFetch`, cached per
		 * artifact id. Stories pass a synthetic fetcher so the play function can
		 * assert the label without a live backend.
		 */
		fetchArtifact?: (id: string) => Promise<ArtifactGrant>;
	} = $props();

	// Cached filename. Resolved on mount from the artifact metadata so the
	// capsule label reads as a filename rather than the raw ULID. Stays `null`
	// until the fetch resolves (or on failure, leaving the id as the fallback
	// label). The download link itself is unaffected — the gateway re-mints a
	// grant on each click regardless of filename resolution.
	let cachedFilename = $state<string | null>(null);

	// Resolve the artifact filename on mount (and when the id changes). The
	// metadata fetch is a plain read; showing the filename pre-click is the
	// same UX contract as reference-fields resolving their display name before
	// render.
	$effect(() => {
		const id = artifactId;
		if (!id) return;
		let cancelled = false;
		void resolveArtifact(id, fetchArtifact)
			.then((grant) => {
				if (cancelled) return;
				cachedFilename = grant.filename;
			})
			.catch(() => {
				// Filename resolution is best-effort. Leave the label as the id;
				// the download link still works (the gateway mints server-side).
			});
		return () => {
			cancelled = true;
		};
	});
</script>

<a
	class="file-artifact capsule-shell"
	href={`/Api/core/artifacts/${artifactId}/download`}
	target="_blank"
	rel="noopener noreferrer external"
	title={cachedFilename ?? `Download artifact ${artifactId}`}
>
	<span class="capsule-shell-text">{cachedFilename ?? artifactId}</span>
	<span class="capsule-shell-icon" aria-hidden="true">
		<Download size={13} />
	</span>
</a>

<style>
	/* FileArtifact — the shared capsule shell in its mono link variant.
	   Mirrors UrlLink so a `file` field reads like the other
	   reference-bearing capsules on the show page (url, reference).
	   Shell (shape, border, fill, truncation, hover) comes from
	   `.capsule-shell`. */
	.file-artifact {
		--tint: var(--accent-ink);
		--capsule-shell-ink: var(--accent-ink);
		--capsule-shell-font: var(--font-mono);
	}
</style>
