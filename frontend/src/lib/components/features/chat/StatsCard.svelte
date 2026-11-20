<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { getLocale } from '$lib/paraglide/runtime';
	import { Sigma } from '@lucide/svelte';
	import Money from '$lib/components/primitives/data/Money.svelte';
	import { humanize } from '$lib/doctype/types.js';
	import type { Stats } from '$lib/assistant/tool-call-helpers.js';

	/**
	 * Metric tiles for a resolved `aggregate_documents` tool call — rendered
	 * in place of the tool bar (`stats` part in `tool-call-helpers.ts`).
	 *
	 * One tile carries the aggregate value: a plain number for `count` and
	 * integer fields, a formatted amount per currency when the field is a
	 * `money` (the per-currency bag `value`), or the raw string for anything
	 * else (duration, decimal). The caption names the aggregate and the
	 * contributing-row count. The value comes from the tool payload — it is
	 * a computed metric, not display data, so it renders as received.
	 */
	let {
		stats
	}: {
		stats: Stats;
	} = $props();

	const AGGREGATE_LABELS: Record<Stats['aggregate'], string> = {
		count: m.assistant_agg_count(),
		sum: m.assistant_agg_sum(),
		avg: m.assistant_agg_average(),
		min: m.assistant_agg_min(),
		max: m.assistant_agg_max()
	};

	/** Bag amounts arrive as decimal strings from the backend — parse for
	 * formatting; an unparsable string falls back to its raw text. */
	function amountOf(v: string | number): number | string {
		if (typeof v === 'number') return v;
		const n = Number(v);
		return Number.isFinite(n) ? n : v;
	}

	const tileCount = $derived(
		stats.value !== null && typeof stats.value === 'object' ? Object.keys(stats.value).length : 1
	);

	const headline = $derived.by(() => {
		if (stats.aggregate === 'count') return m.assistant_stats_matching();
		return stats.field ? humanize(stats.field) : m.assistant_stats_aggregate();
	});

	const caption = $derived.by(() => {
		const parts: string[] = [AGGREGATE_LABELS[stats.aggregate]];
		if (stats.count !== null) {
			parts.push(
				stats.count === 1
					? m.assistant_stats_docs_singular()
					: m.assistant_stats_docs_plural({ count: stats.count })
			);
		}
		return parts.join(' · ');
	});
</script>

<div class="stats-card" data-tiles={tileCount}>
	<header class="stats-head">
		<span class="stats-icon" aria-hidden="true"><Sigma size={13} stroke-width={1.9} /></span>
		<span class="stats-title">{headline}</span>
		<span class="stats-caption">{caption}</span>
	</header>

	<div class="tiles">
		{#if stats.value === null}
			<div class="tile">
				<span class="tile-value blank">—</span>
				<span class="tile-label">{m.assistant_stats_none()}</span>
			</div>
		{:else if typeof stats.value === 'object'}
			{#each Object.entries(stats.value) as [currency, amount] (currency)}
				<div class="tile">
					{#if typeof amountOf(amount) === 'number'}
						<Money amount={amountOf(amount) as number} {currency} />
					{:else}
						<span class="tile-value">{amountOf(amount)}</span>
					{/if}
					<span class="tile-label">{currency}</span>
				</div>
			{/each}
		{:else if typeof stats.value === 'number'}
			<div class="tile">
				<span class="tile-value">{stats.value.toLocaleString(getLocale())}</span>
				{#if stats.aggregate === 'count'}<span class="tile-label"
						>{m.assistant_stats_documents()}</span
					>{/if}
			</div>
		{:else}
			<div class="tile">
				<span class="tile-value">{stats.value}</span>
			</div>
		{/if}
	</div>
</div>

<style>
	.stats-card {
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface);
		overflow: hidden;
		margin-bottom: 9px;
	}

	.stats-head {
		display: flex;
		align-items: center;
		gap: 6px;
		padding: 5px 9px;
		background: var(--surface-2, var(--sunken));
		border-bottom: 1px solid var(--border);
		min-height: 28px;
	}

	.stats-icon {
		display: inline-flex;
		color: var(--text-3);
	}

	.stats-title {
		font-family: var(--font-display);
		font-size: 12px;
		font-weight: 600;
		color: var(--text);
		min-width: 0;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.stats-caption {
		margin-left: auto;
		font-family: var(--font-mono);
		font-size: 10px;
		color: var(--text-3);
		white-space: nowrap;
	}

	.tiles {
		display: flex;
		flex-wrap: wrap;
	}

	.tile {
		flex: 1 1 0;
		min-width: 90px;
		display: flex;
		flex-direction: column;
		align-items: flex-start;
		gap: 1px;
		padding: 8px 12px;
	}

	/* Tiles share one rule — the first tile's left border is trimmed edge-on. */
	.tile + .tile {
		border-left: 1px solid var(--border);
	}

	/* Matches Money's own mono sizing so scalar and per-currency tiles read
	   at the same weight inside one card. */
	.tile-value {
		font-family: var(--font-mono);
		font-size: 13px;
		font-weight: 500;
		color: var(--text);
		line-height: 1.2;
		white-space: nowrap;
	}

	.tile-value.blank {
		color: var(--text-3);
	}

	.tile-label {
		font-family: var(--font-mono);
		font-size: 10px;
		letter-spacing: 0.04em;
		text-transform: uppercase;
		color: var(--text-3);
	}
</style>
