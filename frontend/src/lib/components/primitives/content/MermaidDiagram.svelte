<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	// Lazy-load mermaid exactly once. The library is large (~1MB); we only
	// initialise it when the first diagram is rendered. Subsequent diagrams
	// reuse the same instance.
	let mermaidPromise: Promise<typeof import('mermaid').default> | null = null;

	async function loadMermaid() {
		if (!mermaidPromise) {
			mermaidPromise = import('mermaid').then((m) => {
				const mermaid = m.default;
				mermaid.initialize({
					startOnLoad: false,
					securityLevel: 'strict',
					theme: 'base'
				});
				return mermaid;
			});
		}
		return mermaidPromise;
	}

	// Each diagram needs a unique id for mermaid's internal cache.
	let diagramSeq = 0;
	function nextId(): string {
		diagramSeq += 1;
		return `mmd-${diagramSeq}`;
	}

	export { loadMermaid, nextId };
</script>

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { errorMessage } from '$lib/datasource/bannerError.js';

	let {
		source,
		streaming = false
	}: {
		/** Mermaid diagram source (the contents of the ```mermaid fenced block). */
		source: string;
		/** When true, we don't attempt to render — mermaid needs a complete graph. Shows a placeholder instead. */
		streaming?: boolean;
	} = $props();

	let svg = $state<string>('');
	let error = $state<string>('');
	let loading = $state(false);
	let lastRenderedSrc: string | null = null;

	// Render (or re-render) whenever the source settles. During streaming we
	// skip rendering — an incomplete graph would throw a parse error and
	// flicker. We render once when streaming flips to false, and re-render
	// if the source changes after that (e.g. a correction). The guard on
	// `lastRenderedSrc` skips a redundant render when the source is identical
	// to what was already rendered (avoids re-pinging mermaid on an
	// unrelated prop re-evaluation).
	$effect(() => {
		if (streaming) {
			if (svg !== '') svg = '';
			if (error !== '') error = '';
			lastRenderedSrc = null;
			return;
		}
		const src = source;
		if (!src.trim()) {
			if (svg !== '') svg = '';
			if (error !== '') error = '';
			lastRenderedSrc = null;
			return;
		}
		if (src === lastRenderedSrc) return;
		lastRenderedSrc = src;
		let cancelled = false;
		loading = true;
		error = '';
		loadMermaid()
			.then((mermaid) => mermaid.render(nextId(), src))
			.then((result) => {
				if (cancelled) return;
				svg = result.svg;
				loading = false;
			})
			.catch((e: unknown) => {
				if (cancelled) return;
				error = errorMessage(e);
				loading = false;
			});
		return () => {
			cancelled = true;
		};
	});
</script>

{#if streaming}
	<div class="mmd mmd-pending" role="status" aria-live="polite">
		<span class="mmd-dot"></span>
		<span class="mmd-label">{m.assistant_mermaid_pending()}</span>
	</div>
{:else if error}
	<div class="mmd mmd-error" role="alert">
		<div class="mmd-error-title">{m.assistant_mermaid_invalid()}</div>
		<pre class="mmd-error-detail">{error}</pre>
	</div>
{:else if loading}
	<div class="mmd mmd-pending" role="status" aria-live="polite">
		<span class="mmd-dot"></span>
		<span class="mmd-label">{m.assistant_mermaid_rendering()}</span>
	</div>
{:else if svg}
	<!-- eslint-disable-next-line svelte/no-at-html-tags -- svg comes from mermaid with securityLevel: 'strict' (no scripts) -->
	<div class="mmd mmd-svg">{@html svg}</div>
{/if}

<style>
	.mmd {
		margin: 0 0 12px;
		padding: 14px 16px;
		background: var(--surface-2);
		border: 1px solid var(--border);
		border-radius: var(--r);
		overflow-x: auto;
	}

	.mmd-svg :global(svg) {
		max-width: 100%;
		height: auto;
		display: block;
		margin: 0 auto;
	}

	.mmd-pending {
		display: inline-flex;
		align-items: center;
		gap: 8px;
		font-family: var(--font-mono);
		font-size: 11.5px;
		color: var(--text-3);
	}

	.mmd-dot {
		width: 7px;
		height: 7px;
		border-radius: 50%;
		background: var(--accent);
		animation: mmd-pulse 1s steps(2, start) infinite;
	}

	@keyframes mmd-pulse {
		50% {
			opacity: 0.2;
		}
	}

	.mmd-error {
		background: var(--danger-weak);
		border-color: color-mix(in srgb, var(--danger) 30%, transparent);
	}
	.mmd-error-title {
		font-family: var(--font-mono);
		font-size: 11.5px;
		font-weight: 600;
		color: var(--danger);
		margin-bottom: 6px;
	}
	.mmd-error-detail {
		margin: 0;
		font-family: var(--font-mono);
		font-size: 11px;
		color: var(--text-2);
		white-space: pre-wrap;
		word-break: break-word;
	}

	@media (prefers-reduced-motion: reduce) {
		.mmd-dot {
			animation: none;
			opacity: 0.5;
		}
	}
</style>
