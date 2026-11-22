<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { resolveArtifact, type ArtifactGrant } from '$lib/artifacts.js';

	/**
	 * Dense `file` cell — the listing counterpart of `FileArtifact`.
	 *
	 * The show page renders a download capsule with the artifact's filename.
	 * A listing cell stays compact: it shows the filename when the artifact
	 * metadata is already cached (the show page or a previous cell resolved
	 * it), and falls back to the bare artifact id otherwise. The id stays the
	 * tooltip either way, so the stored value is always readable.
	 *
	 * The resolve is best-effort and never renders a loading state — a failed
	 * or pending fetch leaves the id visible. Concurrent cells for the same
	 * artifact share one request (`resolveArtifact` caches per artifact id).
	 */
	let {
		artifactId,
		fetchArtifact
	}: {
		/** The bare artifact id stored in the document content. */
		artifactId: string;
		/**
		 * Injectable metadata fetch. Defaults to the cached
		 * `GET /Api/core/artifacts/:id` lookup. Stories pass a synthetic
		 * fetcher so the play function can assert the label.
		 */
		fetchArtifact?: (id: string) => Promise<ArtifactGrant>;
	} = $props();

	let filename = $state<string | null>(null);

	$effect(() => {
		const id = artifactId;
		if (!id) return;
		let cancelled = false;
		void resolveArtifact(id, fetchArtifact)
			.then((grant) => {
				if (cancelled) return;
				filename = grant.filename;
			})
			.catch(() => {
				// Filename resolution is best-effort — the id stays the label.
			});
		return () => {
			cancelled = true;
		};
	});
</script>

<span class="cell-text" title={artifactId}>{filename ?? artifactId}</span>
