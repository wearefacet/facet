<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	StatsTile — renders a `stats` agent part: one `aggregate_documents` run.
	A quiet metric tile: the aggregate (plus the field when present) as the
	label, the value in the mono data font, the contributing-row count
	beneath. A per-currency bag renders as `12.00 USD · 3.10 EUR`; `null`
	(empty set) renders as an em dash.

	The main application renders the same part as metric tiles from its
	StatsCard; the tile here is the package's data-only counterpart.
-->
<script lang="ts">
	import * as m from '../messages.js';
	import type { Stats } from './tool-call-helpers.js';

	let { stats }: { stats: Stats } = $props();

	/** Human form of the aggregate label: `sum·amount`. */
	const label = $derived(stats.field ? `${stats.aggregate} · ${stats.field}` : stats.aggregate);

	const value = $derived.by(() => {
		const v = stats.value;
		if (v == null) return '—';
		if (typeof v === 'number') return String(v);
		if (typeof v === 'string') return v;
		// Per-currency bag — keep a stable order.
		return (
			Object.entries(v)
				.map(([currency, amount]) => `${amount} ${currency}`)
				.join(' · ') || '—'
		);
	});
</script>

<div class="stats-tile">
	<span class="stats-label">{label}</span>
	<span class="stats-value">{value}</span>
	{#if stats.count != null}
		<span class="stats-meta">{m.assistant_stats_rows({ count: stats.count })}</span>
	{/if}
</div>

<style>
	.stats-tile {
		display: inline-flex;
		flex-direction: column;
		gap: 2px;
		border: 1px solid var(--facet-border);
		border-radius: var(--facet-r);
		background: var(--facet-surface);
		padding: 8px 12px;
		margin-bottom: 9px;
		min-width: 0;
	}

	.stats-label {
		font-family: var(--facet-font-mono);
		font-size: 10px;
		font-weight: 600;
		letter-spacing: 0.02em;
		color: var(--facet-text-3);
	}

	.stats-value {
		font-family: var(--facet-font-mono);
		font-size: 15px;
		font-weight: 600;
		color: var(--facet-text);
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
		max-width: 100%;
	}

	.stats-meta {
		font-family: var(--facet-font-mono);
		font-size: 10.5px;
		color: var(--facet-text-3);
	}
</style>
