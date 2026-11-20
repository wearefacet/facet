<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { untrack } from 'svelte';
	import { Brain, ChevronRight } from '@lucide/svelte';
	import Markdown from './Markdown.svelte';
	import CopyButton from '$lib/components/primitives/data/CopyButton.svelte';

	/**
	 * ThoughtBlock — a collapsible reasoning block in an agent turn.
	 *
	 * Renders the model's thinking as a `<details>` disclosure: a collapsed
	 * "Thought" header while at rest, and an expandable body streaming the
	 * reasoning via {@link Markdown}.
	 *
	 * While `active` (the reasoning is still streaming) the block is forced
	 * open so the user watches thinking arrive. The moment `active` flips to
	 * `false` — the next part of the turn starts, or the turn ends — the block
	 * collapses once, exactly like a chat that folds away a completed thought.
	 * After that one-shot collapse the user can reopen it freely; a manual
	 * reopen is never overridden by a later `active` change.
	 */
	let {
		content = '',
		active = false
	}: {
		/** Reasoning markdown content. Re-compiled on every change so streaming works. */
		content?: string;
		/** True while this block is still streaming. Forces it open; collapsing on the transition to false. */
		active?: boolean;
	} = $props();

	/** Whether the block is currently expanded. Initial open while active. */
	// svelte-ignore state_referenced_locally — intentional initial seeding
	let open = $state(active);
	/** Whether this block ever streamed (`active` was true at least once). */
	let hasStreamed = $state(false);
	/** Whether the one-shot collapse-on-inactive has already happened. */
	let autoClosed = $state(false);

	// The guards are read through `untrack` so the writes below (which set
	// `autoClosed`) do not re-trigger this effect and cancel the scheduled
	// collapse. `active` is the only tracked dependency.
	$effect(() => {
		if (active) {
			// Streaming thinking stays visible; reset the one-shot guard so a
			// resumed or later stream folds away again once it completes.
			hasStreamed = true;
			autoClosed = false;
			open = true;
			return;
		}
		// Inactive. Only fold once if this block actually streamed — a
		// reconstructed (hand-built) block is left to the user's control. A
		// manual reopen after the fold is never overridden (`autoClosed` guards
		// it). Collapse one tick after `active` drops so the final token stays
		// visible before the block folds away.
		if (!untrack(() => hasStreamed && !autoClosed && open)) return;
		untrack(() => {
			autoClosed = true;
		});
		const t = setTimeout(() => {
			untrack(() => {
				if (!active) open = false;
			});
		}, 0);
		return () => clearTimeout(t);
	});

	/** The copy affordance appears once this block finished streaming and has content. */
	const copyable = $derived(!active && content.trim().length > 0);

	function toggle() {
		open = !open;
	}
</script>

<div class="thought-wrap">
	<details class="thought" class:active {open}>
		<summary class="thought-head" onclick={toggle}>
			<span class="thought-icon" aria-hidden="true">
				<Brain size={13} />
			</span>
			<span class="thought-label">{m.assistant_thought_label()}</span>
			{#if active}
				<span class="thought-dot" aria-hidden="true"></span>
			{/if}
			<span class="thought-spacer"></span>
			<span class="thought-chevron" aria-hidden="true">
				<ChevronRight size={13} stroke-width={1.9} />
			</span>
		</summary>
		<div class="thought-body">
			<Markdown {content} streaming={active} />
		</div>
	</details>
	{#if copyable}
		<!-- Outside the <details> on purpose: a button inside the summary is
		     nested-interactive (axe), and a sibling of the summary would be
		     hidden while the block is collapsed. -->
		<span class="thought-copy">
			<CopyButton value={content} size="sm" iconOnly title={m.assistant_copy_thought()} />
		</span>
	{/if}
</div>

<style>
	/* ── ThoughtBlock — quiet reasoning disclosure, tokens only ─────────── */
	.thought-wrap {
		position: relative;
	}
	.thought {
		display: block;
		font-family: var(--font-mono);
		font-size: 11.5px;
		color: var(--text-3);
		background: var(--surface-2);
		border: 1px solid var(--border);
		border-radius: var(--r);
		margin-bottom: 9px;
		overflow: hidden;
	}

	.thought-head {
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 6px 11px;
		list-style: none;
		cursor: pointer;
		user-select: none;
		transition: background 0.12s ease;
	}
	/* Suppress the default disclosure marker — we render our own chevron. */
	.thought-head::-webkit-details-marker {
		display: none;
	}
	.thought-head:hover {
		background: var(--sunken);
	}

	.thought-icon {
		display: inline-flex;
		color: var(--text-3);
		flex-shrink: 0;
	}

	.thought-label {
		color: var(--text-2);
		font-weight: 600;
	}

	.thought-dot {
		width: 7px;
		height: 7px;
		border-radius: 50%;
		background: var(--accent);
		animation: thought-blink 1s steps(2, start) infinite;
	}

	.thought-spacer {
		flex: 1;
	}

	.thought-chevron {
		flex-shrink: 0;
		color: var(--text-3);
		transition: transform 0.12s ease;
	}
	.thought[open] .thought-chevron {
		transform: rotate(90deg);
	}

	/* ── Copy thought — quiet icon left of the chevron; revealed on hover
	   (and on focus, so keyboard users reach it). Anchored over the header
	   row from outside the disclosure, so it stays reachable while the
	   block is collapsed. ─────────────────────────────────────────── */
	.thought-copy {
		position: absolute;
		top: 3px;
		right: 28px;
		opacity: 0;
		transition: opacity 0.12s ease;
	}
	.thought-wrap:hover .thought-copy,
	.thought-wrap:focus-within .thought-copy {
		opacity: 1;
	}

	/* ── Body — streaming reasoning, dimmed to sit behind the answer ────── */
	.thought-body {
		border-top: 1px solid var(--border);
		background: var(--sunken);
		padding: 8px 12px;
		color: var(--text-2);
	}

	.thought-body :global(.md) :global(p) {
		line-height: 1.6;
		margin: 0 0 8px;
	}
	.thought-body :global(.md) :global(p:last-child) {
		margin-bottom: 0;
	}

	@keyframes thought-blink {
		50% {
			opacity: 0.2;
		}
	}

	@media (prefers-reduced-motion: reduce) {
		.thought-dot {
			animation: none;
			opacity: 0.5;
		}
		.thought-chevron {
			transition: none;
		}
	}
</style>
