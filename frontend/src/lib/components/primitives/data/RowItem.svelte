<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import type { Snippet } from 'svelte';

	let {
		children,
		state,
		empty = false,
		style
	}: {
		children: Snippet;
		/** Optional row state — e.g. `'draft' | 'published'` — carried to `data-state`. */
		state?: string;
		/** When true, renders as a dashed placeholder row. */
		empty?: boolean;
		style?: string;
	} = $props();
</script>

<li class="row-item" class:row-empty={empty} data-state={state} {style}>
	{@render children()}
</li>

<style>
	.row-item {
		display: flex;
		align-items: center;
		gap: 12px;
		padding: 12px 14px;
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface);
	}

	.row-empty {
		border-style: dashed;
		color: var(--text-3);
		justify-content: center;
		padding: 24px;
	}
</style>
