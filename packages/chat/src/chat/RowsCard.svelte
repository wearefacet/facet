<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	RowsCard — renders a `rows` agent part: the page items of a resolved
	`list_documents` call. Each row shows the document identity
	(`{domain}.{doctype}` + id) in the mono data font; the capped match count
	from the payload's `meta` closes the card when present.

	The main application renders the same part as document rows through its
	document cards, which resolve display names from a data source. The
	package carries no data source, so identity is all a row shows — the
	model's own tool output (the raw envelope) stays available in the
	resolving tool-call trace when the turn replays with the parse fallback.
-->
<script lang="ts">
	import * as m from '../messages.js';
	import type { ListRows } from './tool-call-helpers.js';

	let { rows }: { rows: ListRows } = $props();
</script>

<div class="rows-card">
	<ul class="rows-list">
		{#each rows.rows as row (row.domain + '.' + row.doctype + '.' + row.id)}
			<li class="rows-row">
				<span class="rows-doctype">{row.domain}.{row.doctype}</span>
				<span class="rows-id" title={row.id}>{row.id}</span>
			</li>
		{/each}
	</ul>
	{#if rows.total != null}
		<div class="rows-meta">{m.assistant_rows_matches({ count: rows.total })}</div>
	{/if}
</div>

<style>
	.rows-card {
		border: 1px solid var(--facet-border);
		border-radius: var(--facet-r);
		overflow: hidden;
		margin-bottom: 9px;
		background: var(--facet-surface);
	}

	.rows-list {
		list-style: none;
		margin: 0;
		padding: 0;
	}

	.rows-row {
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 6px 10px;
		border-bottom: 1px solid var(--facet-border);
		min-width: 0;
	}

	.rows-row:last-child {
		border-bottom: none;
	}

	.rows-doctype {
		flex-shrink: 0;
		font-family: var(--facet-font-mono);
		font-size: 11px;
		font-weight: 600;
		color: var(--facet-text-2);
		background: var(--facet-sunken);
		border-radius: var(--facet-r-pill);
		padding: 1px 7px;
	}

	.rows-id {
		font-family: var(--facet-font-mono);
		font-size: 11px;
		color: var(--facet-text-3);
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.rows-meta {
		font-family: var(--facet-font-mono);
		font-size: 10.5px;
		color: var(--facet-text-3);
		padding: 4px 10px;
		border-top: 1px solid var(--facet-border);
		background: var(--facet-surface-2);
	}
</style>
