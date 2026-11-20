<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import type { Snippet } from 'svelte';

	let {
		children,
		empty
	}: {
		children: Snippet;
		/** Optional empty-state message rendered when there are no rows. */
		empty?: Snippet;
	} = $props();
</script>

<ul class="row-list" role="list">
	{@render children()}
	{#if empty}
		{@render empty()}
	{/if}
</ul>

<style>
	.row-list {
		list-style: none;
		margin: 0;
		padding: 0;
		display: flex;
		flex-direction: column;
		gap: 6px;
	}
</style>
