<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	let {
		title,
		subtitle,
		actions
	}: {
		title: string;
		/** Optional muted paragraph rendered under the title. */
		subtitle?: string;
		/** Optional right-aligned action controls. */
		actions?: import('svelte').Snippet;
	} = $props();
</script>

<div class="page-head">
	<div class="page-head-left">
		<h1>{title}</h1>
		{#if subtitle}
			<p class="muted">{subtitle}</p>
		{/if}
	</div>
	{#if actions}
		<div class="page-head-actions">
			{@render actions()}
		</div>
	{/if}
</div>

<style>
	.page-head {
		display: flex;
		align-items: flex-start;
		justify-content: space-between;
		gap: 16px;
		margin-bottom: 24px;
	}

	.page-head-left {
		min-width: 0;
	}

	h1 {
		font-family: var(--font-display);
		font-size: 22px;
		font-weight: 600;
		letter-spacing: -0.01em;
		color: var(--text);
	}

	.muted {
		font-size: 13px;
		color: var(--text-3);
		margin-top: 4px;
		line-height: 1.5;
	}

	.page-head-actions {
		display: inline-flex;
		align-items: center;
		gap: 8px;
		flex: none;
	}
</style>
