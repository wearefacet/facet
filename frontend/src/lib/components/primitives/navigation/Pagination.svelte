<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';

	let {
		current = 1,
		total = 1,
		onchange,
		...rest
	}: {
		/** Current page number (1-based). */
		current?: number;
		/** Total number of pages. */
		total?: number;
		/** Called with the target page number when a page is clicked. */
		onchange?: (page: number) => void;
	} = $props();

	const pages = $derived.by(() => {
		if (total <= 7) {
			return Array.from({ length: total }, (_, i) => i + 1);
		}

		const result: (number | '...')[] = [];
		result.push(1);
		if (current > 3) result.push('...');

		const start = Math.max(2, current - 1);
		const end = Math.min(total - 1, current + 1);
		for (let i = start; i <= end; i++) result.push(i);

		if (current < total - 2) result.push('...');
		if (total > 1) result.push(total);

		return result;
	});
</script>

<nav class="pagination" aria-label={m.table_pager_aria()} {...rest}>
	<button
		class="pagination-btn"
		disabled={current <= 1}
		onclick={() => onchange?.(current - 1)}
		aria-label={m.table_pager_prev_aria()}
	>
		‹
	</button>

	{#each pages as page, i (i)}
		{#if page === '...'}
			<span class="pagination-btn" style="cursor: default">…</span>
		{:else if page === current}
			<span class="pagination-current" aria-current="page">{page}</span>
		{:else}
			<button
				class="pagination-btn"
				onclick={() => onchange?.(page)}
				aria-label={m.table_pager_page_aria({ page })}
			>
				{page}
			</button>
		{/if}
	{/each}

	<button
		class="pagination-btn"
		disabled={current >= total}
		onclick={() => onchange?.(current + 1)}
		aria-label={m.table_pager_next_aria()}
	>
		›
	</button>
</nav>

<style>
	/* ── Pagination — matches fullpage .pg and table.css .pg ────────────── */
	.pagination {
		display: inline-flex;
		gap: 4px;
		align-items: center;
	}

	.pagination-btn,
	.pagination-current {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		min-width: 28px;
		height: 28px;
		padding: 0 6px;
		font-size: 12.5px;
		border-radius: var(--r-sm);
		text-decoration: none;
		font-family: var(--font-mono);
	}

	.pagination-btn {
		color: var(--text-2);
		cursor: pointer;
		border: none;
		background: none;
		font: inherit;
	}

	.pagination-btn:hover {
		background: var(--surface-2);
		color: var(--text);
	}

	.pagination-btn:disabled {
		opacity: 0.35;
		cursor: not-allowed;
	}

	.pagination-current {
		color: var(--on-accent);
		background: var(--accent);
		font-weight: 600;
	}
</style>
