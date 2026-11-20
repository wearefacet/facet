<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	// Lazy-load mermaid exactly once. The library is large (~1MB) and ships
	// as an OPTIONAL peer dependency: the host opts in by installing it in
	// its own project. When the module is absent the fenced block renders as
	// plain code — never a bundle-time dependency.
	let mermaidPromise: Promise<typeof import('mermaid').default> | null = null;
	/** Set once the dynamic import has proven the module is not installed. */
	let mermaidUnavailable = false;

	async function loadMermaid() {
		if (mermaidUnavailable) return null;
		if (!mermaidPromise) {
			mermaidPromise = import('mermaid')
				.then((m) => {
					const mermaid = m.default;
					mermaid.initialize({
						startOnLoad: false,
						securityLevel: 'strict',
						theme: 'base'
					});
					return mermaid;
				})
				.catch((e: unknown) => {
					// Module absent (or failed to load) — remember it, and let the
					// caller fall back to the plain code block. The promise resets
					// so a later install-and-reload isn't remembered as broken.
					mermaidUnavailable = true;
					mermaidPromise = null;
					throw e;
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
	import * as m from '../messages.js';

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
	/** True when mermaid is not installed in the host — the block renders as plain code. */
	let plainCode = $state(false);
	let lastRenderedSrc: string | null = null;

	/** Extract a readable message from an unknown rejection. */
	function errorText(e: unknown): string {
		return e instanceof Error ? e.message : String(e);
	}

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
			.then((mermaid) => {
				if (cancelled) return;
				// Optional peer not installed — render the fenced block as plain code.
				if (!mermaid) {
					plainCode = true;
					loading = false;
					return;
				}
				return mermaid.render(nextId(), src).then((result) => {
					if (cancelled) return;
					svg = result.svg;
					loading = false;
				});
			})
			.catch((e: unknown) => {
				if (cancelled) return;
				if (mermaidUnavailable) {
					plainCode = true;
					loading = false;
					return;
				}
				error = errorText(e);
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
{:else if plainCode}
	<!-- No mermaid in the host: the source stays readable as a plain block. -->
	<pre class="mmd mmd-code"><code>{source}</code></pre>
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
		background: var(--facet-surface-2);
		border: 1px solid var(--facet-border);
		border-radius: var(--facet-r);
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
		font-family: var(--facet-font-mono);
		font-size: 11.5px;
		color: var(--facet-text-3);
	}

	.mmd-dot {
		width: 7px;
		height: 7px;
		border-radius: 50%;
		background: var(--facet-accent);
		animation: mmd-pulse 1s steps(2, start) infinite;
	}

	@keyframes mmd-pulse {
		50% {
			opacity: 0.2;
		}
	}

	/* Plain-code fallback — mirrors the Markdown component's fenced block. */
	.mmd-code {
		margin: 0;
		font-family: var(--facet-font-mono);
		font-size: 12.5px;
		line-height: 1.55;
		color: var(--facet-text);
		background: none;
		border: none;
		padding: 0;
		white-space: pre;
	}

	.mmd-error {
		background: var(--facet-danger-weak);
		border-color: color-mix(in srgb, var(--facet-danger) 30%, transparent);
	}
	.mmd-error-title {
		font-family: var(--facet-font-mono);
		font-size: 11.5px;
		font-weight: 600;
		color: var(--facet-danger);
		margin-bottom: 6px;
	}
	.mmd-error-detail {
		margin: 0;
		font-family: var(--facet-font-mono);
		font-size: 11px;
		color: var(--facet-text-2);
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
