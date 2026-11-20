<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import RelativeTime from '$lib/components/primitives/data/RelativeTime.svelte';
	import Capsule from '$lib/components/primitives/data/Capsule.svelte';
	import FilterBar from '$lib/components/primitives/navigation/FilterBar.svelte';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { MutationRecord } from '$lib/datasource/types.js';
	import type { DoctypeDef } from '$lib/doctype/types.js';
	import { actionVariant, channelLabel, isAccountActioner } from './auditDiff.js';
	import * as messages from '$lib/paraglide/messages';

	let {
		items = [] as MutationRecord[],
		loading = false,
		error = undefined as string | undefined,
		meta = null as { count: number; more: boolean } | null,
		page = 1,
		pageSize = 25,
		selectedId = null as string | null,
		filters = {} as Record<string, unknown>,
		/** Filter schema for the shared FilterBar — `auditFilterDoctype(...)` from the page. */
		doctype = undefined as DoctypeDef | undefined,
		driver = undefined as DataDriver | undefined,
		emptyMessage = messages.audit_table_empty(),
		onFilterChange,
		onPageChange,
		onSelect,
		onOpenDocument,
		/** Opens the mutation's actor account in the QuickView peek drawer. */
		onOpenActor
	}: {
		/** Rows for the current page (already fetched by the parent page). */
		items?: MutationRecord[];
		loading?: boolean;
		error?: string;
		/** Response meta: capped `count` and `more` flag — pagination runs on `more`, never on exact totals. */
		meta?: { count: number; more: boolean } | null;
		page?: number;
		/** Rows requested per page — next-page presence is `items.length === pageSize`. */
		pageSize?: number;
		/** ULID of the mutation highlighted in the detail panel. */
		selectedId?: string | null;
		/** Active filter map (`field__op` → value), owned by the parent page. */
		filters?: Record<string, unknown>;
		/** Filter schema driving the shared FilterBar; when undefined, no filter bar renders. */
		doctype?: DoctypeDef;
		/** Driver used to hydrate the document capsules and the actor reference combobox. */
		driver?: DataDriver;
		/** Message shown when the log has no rows. */
		emptyMessage?: string;
		onFilterChange?: (filters: Record<string, unknown>) => void;
		onPageChange?: (page: number) => void;
		onSelect?: (mutation: MutationRecord | null) => void;
		/** Opens the mutation's document in the QuickView peek drawer. */
		onOpenDocument?: (mutation: MutationRecord) => void;
		/** Opens the mutation's actor account in the QuickView peek drawer. */
		onOpenActor?: (e: { domain: string; doctype: string; id: string }) => void;
	} = $props();

	const canGoPrev = $derived(page > 1);
	const canGoNext = $derived(items.length === pageSize);

	/** Exact totals shown only when `more` is false; the count is capped at 1000. */
	const countLabel = $derived(
		meta == null
			? ''
			: meta.more
				? messages.audit_more_records()
				: meta.count === 1
					? messages.audit_total_count_singular({ count: meta.count })
					: messages.audit_total_count_plural({ count: meta.count })
	);
</script>

<div class="audit-table">
	{#if doctype}
		<div class="filter-bar" role="search" aria-label={messages.audit_filters_aria()}>
			<!-- Schema-aware filter bar (the same one the table surface uses).
					 The audit backend answers no `created_at`/`updated_at` keys, so the
					 synthesized system-timestamp filters stay off. -->
			<FilterBar {doctype} {driver} {filters} {onFilterChange} showSystemTimestamps={false} />
		</div>
	{/if}

	{#if error}
		<div class="table-error" role="alert">{error}</div>
	{/if}

	<div class="table-scroll">
		<table>
			<thead>
				<tr>
					<th style="width: 110px">{messages.audit_action_column()}</th>
					<th style="width: 2fr">{messages.audit_document_column()}</th>
					<th style="width: 1.2fr">{messages.audit_actor_column()}</th>
					<th style="width: 110px">{messages.audit_channel_column()}</th>
					<th style="width: 110px">{messages.audit_when_column()}</th>
				</tr>
			</thead>
			<tbody>
				{#each items as m (m.id)}
					{@const variant = actionVariant(m)}
					<tr
						class="row"
						class:clickable={true}
						class:selected={m.id === selectedId}
						onclick={() => onSelect?.(m)}
						onkeydown={(e) => {
							if (e.key === 'Enter' || e.key === ' ') {
								e.preventDefault();
								onSelect?.(m);
							}
						}}
						tabindex="0"
					>
						<td>
							<span class={`action-badge action-${variant.tone}`}>{variant.label}</span>
						</td>
						<td>
							<!-- Doctype capsule: hydrates the document display name and the
							     doctype tint; the click opens the QuickView peek drawer
							     (the Capsule stops propagation, so the row stays unselected). -->
							<Capsule
								{driver}
								reference={`${m.domain}.${m.doc_type}.${m.doc_id}`}
								label={m.doc_id}
								onreferenceclick={onOpenDocument ? () => onOpenDocument?.(m) : undefined}
							/>
						</td>
						<td>
							<!-- Actor capsule: hydrates the account display name and opens
							     the account in the QuickView peek drawer. Machine
							     principals (`system`, …) are not accounts — they render
							     as plain text instead of a failed capsule. -->
							{#if isAccountActioner(m.actioner_id)}
								<Capsule
									{driver}
									reference={m.actioner_id}
									qualifiedDoctype="iam.Account"
									label={m.actioner_id}
									onreferenceclick={onOpenActor}
								/>
							{:else}
								<code class="actor-plain">{m.actioner_id}</code>
							{/if}
						</td>
						<td>
							<!-- Wire value in the title so `facet` stays traceable to its
									 `session` channel; the label matches the detail panel's
									 `via` line. -->
							<span class="channel-cell" title={m.channel}>{channelLabel(m.channel)}</span>
						</td>
						<td><RelativeTime date={m.emitted_at} /></td>
					</tr>
				{:else}
					{#if !loading && !error}
						<tr class="row-empty">
							<td colspan="5">{emptyMessage}</td>
						</tr>
					{/if}
				{/each}
			</tbody>
		</table>
	</div>

	{#if loading && items.length === 0}
		<div class="table-loading">{messages.common_loading()}</div>
	{/if}

	<div class="table-foot">
		<span class="foot-info">
			{#if meta}
				{messages.audit_page_count({ page })}{#if countLabel}&nbsp;· {countLabel}{/if}
			{/if}
		</span>
		<span class="sp"></span>
		<div class="pager">
			<button
				type="button"
				class="pager-btn"
				disabled={!canGoPrev}
				onclick={() => onPageChange?.(page - 1)}
			>
				{messages.audit_pager_previous()}
			</button>
			<button
				type="button"
				class="pager-btn"
				disabled={!canGoNext}
				onclick={() => onPageChange?.(page + 1)}
			>
				{messages.audit_pager_next()}
			</button>
		</div>
	</div>
</div>

<style>
	.audit-table {
		display: flex;
		flex-direction: column;
		gap: 12px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: var(--sh-1);
		padding: 16px;
		min-width: 0;
	}

	/* ── Filter bar ─────────────────────────────────────────── */
	/* The shared FilterBar owns its chip layout; this wrapper only gives the
	   region its spacing block. */
	.filter-bar {
		min-width: 0;
	}

	/* ── Table ────────────────────────────────────────────────────────── */
	.table-scroll {
		overflow-x: auto;
	}

	table {
		width: 100%;
		border-collapse: collapse;
	}

	thead th {
		text-align: left;
		font-size: 11.5px;
		font-weight: 600;
		color: var(--text-3);
		text-transform: uppercase;
		letter-spacing: 0.04em;
		padding: 8px 10px;
		border-bottom: 1px solid var(--border);
		white-space: nowrap;
	}

	tbody td {
		padding: 9px 10px;
		font-size: 12.5px;
		color: var(--text);
		border-bottom: 1px solid var(--border);
		vertical-align: middle;
	}

	.row {
		cursor: pointer;
	}

	.row:hover {
		background: var(--sunken);
	}

	.row:focus-visible {
		outline: 2px solid var(--accent);
		outline-offset: -2px;
	}

	.row.selected {
		background: var(--sunken);
	}

	.row-empty td {
		text-align: center;
		color: var(--text-3);
		padding: 24px 10px;
	}

	/* ── Cells ────────────────────────────────────────────────────────── */
	/* ── Cells ──────────────────────────────────────────── */
	/* Machine-principal actor ids (`system`, …) — plain mono, no capsule. */
	.actor-plain {
		font-family: var(--font-mono);
		font-size: 11.5px;
		color: var(--text-2);
	}

	/* Auth channel — categorical, so it stays neutral (no tint). */
	.channel-cell {
		font-family: var(--font-mono);
		font-size: 11.5px;
		color: var(--text-2);
	}

	.action-badge {
		display: inline-block;
		padding: 3px 9px;
		border-radius: 999px;
		font-size: 11px;
		font-weight: 600;
		white-space: nowrap;
	}

	.action-ok {
		background: var(--ok-weak);
		color: var(--ok);
	}

	.action-info {
		background: var(--info-weak);
		color: var(--info);
	}

	.action-danger {
		background: var(--danger-weak);
		color: var(--danger);
	}

	.action-neutral {
		background: var(--sunken);
		color: var(--text-2);
	}

	/* ── Footer / pagination ─────────────────────────────────── */
	.table-loading {
		text-align: center;
		font-size: 12.5px;
		color: var(--text-3);
		padding: 16px;
	}

	.table-foot {
		display: flex;
		align-items: center;
		gap: 12px;
		flex-wrap: wrap;
	}

	.foot-info {
		font-size: 12px;
		color: var(--text-3);
	}

	.sp {
		flex: 1;
	}

	.pager {
		display: flex;
		gap: 8px;
	}

	.pager-btn {
		padding: 6px 12px;
		border: 1px solid var(--border-strong);
		border-radius: var(--r);
		background: var(--surface);
		color: var(--text);
		font-size: 12px;
		font-weight: 600;
		cursor: pointer;
	}

	.pager-btn:hover:not(:disabled) {
		background: var(--sunken);
	}

	.pager-btn:focus-visible {
		outline: 2px solid var(--accent);
		outline-offset: 1px;
	}

	.pager-btn:disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}

	/* ── Error ───────────────────────────────────────────────────────── */
	.table-error {
		padding: 10px 12px;
		border-radius: var(--r);
		background: var(--danger-weak);
		color: var(--danger);
		font-size: 13px;
	}

	@media (max-width: 900px) {
		.table-foot {
			flex-direction: column;
			align-items: flex-start;
		}
	}
</style>
