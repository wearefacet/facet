<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';

	type Tab = {
		label: string;
		count?: number;
		error?: boolean;
	};

	let {
		tabs,
		active = $bindable(0),
		onchange,
		icon,
		trailing,
		...rest
	}: {
		/** Tab definitions. */
		tabs: Tab[];
		/** Index of the currently active tab. */
		active?: number;
		/** Called when the active tab changes. */
		onchange?: (index: number) => void;
		/** Optional lead icon, rendered per tab with its index. */
		icon?: import('svelte').Snippet<[index: number]>;
		/** Optional actions rendered after the last tab (add button, view actions). */
		trailing?: import('svelte').Snippet;
		children?: import('svelte').Snippet;
	} = $props();

	function handleClick(index: number) {
		active = index;
		onchange?.(index);
	}
</script>

<div class="tabs" role="tablist" {...rest}>
	{#each tabs as tab, i (i)}
		<button
			class="tab-btn"
			class:tab-on={i === active}
			role="tab"
			aria-selected={i === active}
			onclick={() => handleClick(i)}
		>
			{#if icon}
				{@render icon(i)}
			{/if}
			{tab.label}
			{#if tab.count != null}
				<span class="tab-count">{tab.count}</span>
			{/if}
			{#if tab.error}
				<span class="tab-err" aria-label={m.list_tab_error_aria()}></span>
			{/if}
		</button>
	{/each}
	{#if trailing}
		{@render trailing()}
	{/if}
</div>

<style>
	/* ── Tabs — matches design-guideline .tabs ───────────────────────── */
	.tabs {
		display: flex;
		gap: 2px;
		border-bottom: 1px solid var(--border);
		margin-bottom: 0;
		padding: 0 4px;
	}

	.tab-btn {
		padding: 12px 15px;
		font-size: 13px;
		font-weight: 600;
		font-family: var(--font-sans);
		color: var(--text-2);
		border: none;
		background: none;
		border-bottom: 2px solid transparent;
		margin-bottom: -1px;
		display: inline-flex;
		align-items: center;
		gap: 8px;
		cursor: pointer;
		white-space: nowrap;
	}

	.tab-btn:hover {
		color: var(--text);
	}

	.tab-on {
		color: var(--accent-ink);
		border-bottom-color: var(--accent);
	}

	/* Count badge — matches .tabs button .n */
	.tab-count {
		font-family: var(--font-mono);
		font-size: 10.5px;
		background: var(--sunken);
		border-radius: var(--r-pill);
		padding: 0 6px;
		color: var(--text-3);
		font-weight: 500;
		line-height: 1.7;
	}

	.tab-on .tab-count {
		background: var(--accent-weak);
		color: var(--accent-ink);
	}

	/* Error indicator dot — matches .tabs button .err */
	.tab-err {
		width: 6px;
		height: 6px;
		border-radius: 50%;
		background: var(--danger);
		flex-shrink: 0;
	}
</style>
