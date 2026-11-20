<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	let {
		daymark,
		children
	}: {
		/** Optional divider label rendered at the top of the thread (e.g. "New domain · logistics"). */
		daymark?: string;
		children?: import('svelte').Snippet;
	} = $props();
</script>

<div class="thread">
	{#if daymark}
		<div class="daymark">{daymark}</div>
	{/if}
	{@render children?.()}
</div>

<style>
	/* ── ChatThread — matches .thread / .daymark from mockup ────────────── */
	.thread {
		display: flex;
		flex-direction: column;
		gap: 18px;
	}

	.daymark {
		display: flex;
		align-items: center;
		gap: 10px;
		color: var(--facet-text-3);
		font-size: 11px;
		font-weight: 600;
		letter-spacing: 0.04em;
		text-transform: uppercase;
	}
	.daymark::before,
	.daymark::after {
		content: '';
		height: 1px;
		background: var(--facet-border);
		flex: 1;
	}
</style>
