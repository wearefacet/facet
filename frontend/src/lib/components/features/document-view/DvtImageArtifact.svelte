<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { getDocContent, resolveInterpolated } from '$lib/template-resolve';
	import type { ImageArtifactNode, ReferenceClickHandler } from '$lib/template-types';
	import type { DocumentResponse } from '$lib/datasource/types';
	import ArtifactImage from './ArtifactImage.svelte';
	import type { ArtifactGrant } from '$lib/artifacts.js';

	let {
		template,
		document,
		fetchArtifact,
		onreferenceclick: _onreferenceclick
	}: {
		/** The image-artifact template node. */
		template: ImageArtifactNode;
		/** The full document response. */
		document: DocumentResponse;
		/**
		 * Injectable artifact metadata fetcher — used by `ArtifactImage` to
		 * resolve the artifact id to a grant URL. Defaults to
		 * `GET /Api/core/artifacts/:id` via `apiFetch`. Stories pass a
		 * synthetic fetcher so the play function can assert the image renders
		 * without a live backend.
		 */
		fetchArtifact?: (id: string) => Promise<ArtifactGrant>;
		/** Reference capsule click handler forwarded by parent (unused, kept
		 *  for registry signature uniformity). */
		onreferenceclick?: ReferenceClickHandler;
	} = $props();

	const content = $derived(getDocContent(document));
	const rawValue = $derived(content[template.field]);
	const artifactId = $derived(typeof rawValue === 'string' ? rawValue : '');
	const altText = $derived(template.alt ? resolveInterpolated(template.alt, content) : '');
</script>

{#if artifactId}
	<ArtifactImage
		{artifactId}
		{fetchArtifact}
		variant={template.variant ?? 'thumbnail'}
		alt={altText}
		size={template.size}
	/>
{:else}
	<span class="dvt-image-artifact-blank" aria-hidden="true">—</span>
{/if}

<style>
	.dvt-image-artifact-blank {
		color: var(--text-3);
		font-family: var(--font-mono);
	}
</style>
