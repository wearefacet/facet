<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { untrack } from 'svelte';
	import { renderMarkdown, highlightCode, type Segment } from './markdown-renderer.js';
	import MermaidDiagram from './MermaidDiagram.svelte';

	let { content = '', streaming = false }: { content?: string; streaming?: boolean } = $props();

	// Markdown re-parse is O(n) in the content length. A verbose streaming
	// turn (reasoning or long content) emits one token per SSE chunk, so a
	// $derived would re-parse the entire content on every token — O(n²)
	// across the stream, which freezes the main thread once the buffer grows.
	//
	// Throttle re-parses to one per animation frame while streaming, so the
	// cost is O(n) per frame regardless of token rate. Non-streaming content
	// (history reconstruction, persisted turns) re-parses eagerly since its
	// `content` changes once and a frame delay would cause a visible blink.
	//
	// The initial parse reads `content` untracked so Svelte does not warn
	// about the initial-value capture — the effect below owns all subsequent
	// updates and is the single source of reactive truth.
	let segments: Segment[] = $state(untrack(() => renderMarkdown(content)));
	// svelte-ignore state_referenced_locally — intentional initial seeding.
	let lastParsed = content;

	$effect(() => {
		if (!streaming) {
			// Non-streaming: parse synchronously so the initial render is correct.
			// The `content !== lastParsed` guard skips a redundant re-parse when
			// an unrelated prop re-triggers the effect without a content change.
			// `lastParsed` is updated inside the streaming rAF callback (after the
			// parse fires), so a transition streaming→settled parses once only if
			// the last streamed rAF was canceled before firing.
			if (content !== lastParsed) {
				lastParsed = content;
				segments = renderMarkdown(content);
			}
			return;
		}
		const latest = content;
		const raf = requestAnimationFrame(() => {
			segments = renderMarkdown(latest);
			lastParsed = latest;
		});
		return () => cancelAnimationFrame(raf);
	});
</script>

<div class="md">
	{#each segments as seg, i (seg.kind + ':' + i)}
		{#if seg.kind === 'html'}
			<!-- eslint-disable svelte/no-at-html-tags -- html segments are built by
				markdown-renderer: inline tags are allowlisted, attributes stripped,
				unknown tags escaped (see sanitizeInlineHtml). highlight.js escapes
				the code it emits; only its own span markup reaches the DOM. -->
			{@html seg.html}
			<!-- eslint-enable svelte/no-at-html-tags -->
		{:else if seg.kind === 'code'}
			<!-- eslint-disable svelte/no-at-html-tags -- highlight.js escapes the
				source; only its own span markup is emitted. -->
			<pre class="md-code" data-lang={seg.lang ?? undefined}><code
					>{@html highlightCode(seg.code, seg.lang)}</code
				></pre>
			<!-- eslint-enable svelte/no-at-html-tags -->
		{:else if seg.kind === 'mermaid'}
			<MermaidDiagram source={seg.source} {streaming} />
		{/if}
	{/each}
	{#if streaming}
		<span class="md-caret" aria-hidden="true"></span>
	{/if}
</div>

<style>
	/* ── Markdown — matches the .doc surface from table.html ─────────────── */
	.md :global(p) {
		margin: 0 0 9px;
		line-height: 1.6;
	}
	.md :global(p:last-child) {
		margin-bottom: 0;
	}
	.md :global(h1),
	.md :global(h2),
	.md :global(h3),
	.md :global(h4) {
		font-family: var(--facet-font-display);
		font-weight: 600;
		letter-spacing: -0.01em;
		margin: 16px 0 8px;
		line-height: 1.3;
	}
	.md :global(h1) {
		font-size: 20px;
	}
	.md :global(h2) {
		font-size: 17px;
	}
	.md :global(h3) {
		font-size: 15px;
	}
	.md :global(h4) {
		font-size: 13.5px;
	}
	.md :global(ul),
	.md :global(ol) {
		margin: 0 0 9px;
		padding-left: 22px;
	}
	.md :global(ul) {
		list-style: disc;
	}
	.md :global(ol) {
		list-style: decimal;
	}
	.md :global(ul ul),
	.md :global(ol ul) {
		list-style: circle;
	}
	.md :global(ul ul ul),
	.md :global(ul ol ul),
	.md :global(ol ul ul),
	.md :global(ol ol ul) {
		list-style: square;
	}
	.md :global(ol ol),
	.md :global(ul ol) {
		list-style: lower-alpha;
	}
	.md :global(li) {
		margin: 4px 0;
		line-height: 1.55;
		padding-left: 2px;
	}
	.md :global(li::marker) {
		color: var(--facet-text-3);
	}
	/* Task list items — no bullet, a status dot instead. */
	.md :global(li.md-task) {
		list-style: none;
		padding-left: 0;
		margin-left: -6px;
		position: relative;
		padding-left: 20px;
	}
	.md :global(li.md-task::before) {
		content: '';
		position: absolute;
		left: 0;
		top: 0.55em;
		width: 14px;
		height: 14px;
		border-radius: 4px;
		border: 1.5px solid var(--facet-border-strong, var(--facet-border));
		background: var(--facet-surface-2);
	}
	.md :global(li.md-task[data-checked='true']::before) {
		background: var(--facet-ok);
		border-color: var(--facet-ok);
		background-image: linear-gradient(45deg, transparent 45%, #fff 45%, #fff 58%, transparent 58%);
		background-size: 9px 9px;
		background-repeat: no-repeat;
		background-position: center;
	}
	.md :global(li.md-task[data-checked='true']) {
		color: var(--facet-text-3);
		text-decoration: line-through;
		text-decoration-color: var(--facet-text-3);
	}
	/* Definition lists */
	.md :global(dl) {
		margin: 0 0 10px;
	}
	.md :global(dt) {
		font-weight: 600;
		font-family: var(--facet-font-display);
		margin-top: 6px;
	}
	.md :global(dt:first-child) {
		margin-top: 0;
	}
	.md :global(dd) {
		margin: 2px 0 0 18px;
		color: var(--facet-text-2);
	}
	/* Inline highlighting, sub/sup, kbd */
	.md :global(mark) {
		background: var(--facet-warn-weak, #fff3cd);
		color: var(--facet-warn-ink, inherit);
		border-radius: 3px;
		padding: 0 3px;
	}
	.md :global(sub),
	.md :global(sup) {
		font-size: 0.78em;
		line-height: 0;
	}
	.md :global(kbd) {
		font-family: var(--facet-font-mono);
		font-size: 12px;
		background: var(--facet-surface-2);
		border: 1px solid var(--facet-border);
		border-bottom-width: 2px;
		border-radius: 5px;
		padding: 1px 6px;
		line-height: 1.4;
		white-space: nowrap;
	}
	.md :global(code) {
		font-family: var(--facet-font-mono);
		font-size: 12.5px;
		background: var(--facet-sunken);
		border: 1px solid var(--facet-border);
		border-radius: 5px;
		padding: 1px 6px;
	}
	.md :global(blockquote) {
		margin: 10px 0;
		padding: 8px 14px;
		border-left: 3px solid var(--facet-accent);
		background: var(--facet-accent-weak);
		border-radius: 0 var(--facet-r-sm) var(--facet-r-sm) 0;
		color: var(--facet-text);
		font-size: 13.5px;
	}
	.md :global(blockquote p) {
		margin: 0;
	}
	.md :global(a) {
		color: var(--facet-accent-ink);
		text-decoration: underline;
		text-underline-offset: 2px;
	}
	.md :global(a:hover) {
		color: var(--facet-accent);
	}
	.md :global(hr) {
		border: none;
		border-top: 1px solid var(--facet-border);
		margin: 14px 0;
	}
	.md :global(strong) {
		font-weight: 600;
	}
	.md :global(img) {
		max-width: 100%;
		height: auto;
		border-radius: var(--facet-r);
		border: 1px solid var(--facet-border);
		margin: 4px 0;
	}

	/* ── Tables ─────────────────────────────────────────────────────────── */
	.md :global(.md-tbl-wrap) {
		margin: 0 0 12px;
		overflow-x: auto;
		border: 1px solid var(--facet-border);
		border-radius: var(--facet-r);
	}
	.md :global(table) {
		border-collapse: collapse;
		width: 100%;
		font-size: 13px;
	}
	.md :global(th),
	.md :global(td) {
		padding: 8px 12px;
		border-bottom: 1px solid var(--facet-border);
		text-align: left;
	}
	.md :global(th) {
		background: var(--facet-surface-2);
		font-weight: 600;
		font-family: var(--facet-font-display);
		white-space: nowrap;
	}
	.md :global(td) {
		color: var(--facet-text-2);
	}
	.md :global(tr:last-child td) {
		border-bottom: none;
	}
	.md :global(.md-tbl-center) {
		text-align: center;
	}
	.md :global(.md-tbl-right) {
		text-align: right;
	}

	/* ── Fenced code blocks (highlight.js) ──────────────────────────────── */
	.md-code {
		margin: 0 0 12px;
		padding: 12px 14px;
		background: var(--facet-sunken);
		border: 1px solid var(--facet-border);
		border-radius: var(--facet-r);
		overflow-x: auto;
		position: relative;
	}
	.md-code code {
		display: block;
		font-family: var(--facet-font-mono);
		font-size: 12.5px;
		line-height: 1.55;
		color: var(--facet-text);
		background: none;
		border: none;
		padding: 0;
		white-space: pre;
	}

	/* highlight.js token colours — themed to the design system. */
	.md-code :global(.hljs-keyword),
	.md-code :global(.hljs-selector-tag),
	.md-code :global(.hljs-built_in) {
		color: var(--facet-info);
		font-weight: 600;
	}
	.md-code :global(.hljs-string),
	.md-code :global(.hljs-attr),
	.md-code :global(.hljs-template-tag) {
		color: var(--facet-ok);
	}
	.md-code :global(.hljs-number),
	.md-code :global(.hljs-literal) {
		color: var(--facet-accent-ink);
	}
	.md-code :global(.hljs-comment),
	.md-code :global(.hljs-doctag) {
		color: var(--facet-text-3);
		font-style: italic;
	}
	.md-code :global(.hljs-title),
	.md-code :global(.hljs-section),
	.md-code :global(.hljs-name) {
		color: var(--facet-accent-ink);
		font-weight: 600;
	}
	.md-code :global(.hljs-variable),
	.md-code :global(.hljs-attribute),
	.md-code :global(.hljs-property) {
		color: var(--facet-text);
	}
	.md-code :global(.hljs-type),
	.md-code :global(.hljs-class .hljs-title) {
		color: var(--facet-warn);
		font-weight: 600;
	}
	.md-code :global(.hljs-meta) {
		color: var(--facet-text-3);
	}
	.md-code :global(.hljs-emphasis) {
		font-style: italic;
	}
	.md-code :global(.hljs-strong) {
		font-weight: 700;
	}
	.md-code :global(.hljs-addition) {
		color: var(--facet-ok);
	}
	.md-code :global(.hljs-deletion) {
		color: var(--facet-danger);
	}

	/* Streaming caret — a soft blinking block at the end of the bubble. */
	.md-caret {
		display: inline-block;
		width: 7px;
		height: 1.05em;
		margin-left: 2px;
		vertical-align: text-bottom;
		background: var(--facet-accent);
		border-radius: 1px;
		animation: md-blink 1s steps(2, start) infinite;
	}

	@keyframes md-blink {
		50% {
			opacity: 0;
		}
	}

	@media (prefers-reduced-motion: reduce) {
		.md-caret {
			animation: none;
			opacity: 0.5;
		}
	}
</style>
