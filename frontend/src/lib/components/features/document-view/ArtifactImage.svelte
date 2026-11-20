<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import type { ArtifactGrant } from '$lib/components/primitives/data/FileArtifact.svelte';

	/**
	 * Presentational cell that resolves a stored artifact id to a displayable
	 * `<img>` on mount and renders it as a circular avatar or a square
	 * thumbnail.
	 *
	 * The stored value of a `file`-typed field is the bare 26-char artifact
	 * ULID; the displayable URL is the `url` field returned by
	 * `GET /Api/core/artifacts/:id` (an ephemeral grant). This component owns
	 * that single fetch + the `<img>` rendering, so the `image-artifact` DVT
	 * node and the `HeaderNode.logo` header avatar share one implementation.
	 *
	 * Mirrors `FileArtifact.svelte`'s fetch contract: defaults to
	 * `GET /Api/core/artifacts/:id` via `apiFetch`; stories pass a synthetic
	 * fetcher so play functions can assert the image renders without a live
	 * backend.
	 */
	let {
		artifactId,
		fetchArtifact,
		variant = 'thumbnail',
		alt = '',
		size
	}: {
		/** The bare artifact id stored in the document content. */
		artifactId: string;
		/**
		 * Injectable fetch — receives the artifact id and returns the grant
		 * metadata (only the `url` member is used). Defaults to
		 * `GET /Api/core/artifacts/:id` via `apiFetch`.
		 */
		fetchArtifact?: (id: string) => Promise<ArtifactGrant>;
		/** Render shape. `avatar` = circular; `thumbnail` = square with border. */
		variant?: 'avatar' | 'thumbnail';
		/** Alt text for the `<img>`. */
		alt?: string;
		/** Optional explicit pixel size (overrides the variant default). */
		size?: number;
	} = $props();

	// Resolved grant URL — `null` until the fetch resolves (or fails, in which
	// case the muted placeholder stays). The fetch is best-effort: a failed
	// resolve leaves the placeholder visible rather than throwing.
	let srcUrl = $state<string | null>(null);
	let failed = $state(false);

	$effect(() => {
		const id = artifactId;
		if (!id) {
			srcUrl = null;
			failed = false;
			return;
		}
		let cancelled = false;
		void (async () => {
			try {
				const grant = await resolveGrant(id);
				if (cancelled) return;
				srcUrl = grant.url;
				failed = false;
			} catch {
				if (cancelled) return;
				srcUrl = null;
				failed = true;
			}
		})();
		return () => {
			cancelled = true;
		};
	});

	async function resolveGrant(id: string): Promise<ArtifactGrant> {
		if (fetchArtifact) return fetchArtifact(id);
		const { apiFetch } = await import('$lib/session.svelte');
		const res = await apiFetch(`/Api/core/artifacts/${id}`);
		if (!res.ok) {
			throw new Error(`Fetch failed (${res.status})`);
		}
		return (await res.json()) as ArtifactGrant;
	}

	const dim = $derived(size ?? (variant === 'avatar' ? 72 : 40));
</script>

{#if srcUrl}
	<img
		class="artifact-image"
		class:avatar={variant === 'avatar'}
		class:thumbnail={variant === 'thumbnail'}
		style="width:{dim}px;height:{dim}px"
		src={srcUrl}
		{alt}
		loading="lazy"
	/>
{:else}
	<span
		class="artifact-image-placeholder"
		class:avatar={variant === 'avatar'}
		class:thumbnail={variant === 'thumbnail'}
		class:failed
		style="width:{dim}px;height:{dim}px"
		aria-hidden="true"
	></span>
{/if}

<style>
	.artifact-image,
	.artifact-image-placeholder {
		display: block;
		flex-shrink: 0;
		object-fit: cover;
		background: var(--sunken);
	}

	.artifact-image.avatar,
	.artifact-image-placeholder.avatar {
		border-radius: 50%;
		border: 1px solid var(--border-strong);
	}

	.artifact-image.thumbnail,
	.artifact-image-placeholder.thumbnail {
		border-radius: var(--r-sm);
		border: 1px solid var(--border);
	}

	.artifact-image-placeholder.failed {
		background: color-mix(in srgb, var(--danger) 8%, var(--sunken));
		border-color: color-mix(in srgb, var(--danger) 35%, var(--border));
	}
</style>
