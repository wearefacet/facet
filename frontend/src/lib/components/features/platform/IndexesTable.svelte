<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import RelativeTime from '$lib/components/primitives/data/RelativeTime.svelte';
	import Select, { type SelectOption } from '$lib/components/primitives/forms/Select.svelte';
	import Input from '$lib/components/primitives/forms/Input.svelte';
	import { RefreshCw } from '@lucide/svelte';
	import type { IndexRow, IndexStatus } from './IndexesSource.js';
	import * as messages from '$lib/paraglide/messages';

	let {
		items = [] as IndexRow[],
		loading = false,
		error = undefined as string | undefined,
		meta = null as { count: number; more: boolean } | null,
		page = 1,
		pageSize = 25,
		filters = {} as Record<string, unknown>,
		emptyMessage = messages.platform_indexes_table_empty(),
		refreshing = false,
		onFilterChange,
		onPageChange,
		onRefresh
	}: {
		/** Rows for the current page (already fetched by the parent page). */
		items?: IndexRow[];
		loading?: boolean;
		error?: string;
		/** Response meta: real capped `count` and `more` flag. `more` means the count was truncated, not that a next page exists. */
		meta?: { count: number; more: boolean } | null;
		page?: number;
		/** Rows requested per page — next-page presence is `items.length === pageSize`. */
		pageSize?: number;
		/** Active filter map (`field__op` → value), owned by the parent page. */
		filters?: Record<string, unknown>;
		/** Message shown when no rows match. */
		emptyMessage?: string;
		/** True while a manual refresh is in flight — the button shows it. */
		refreshing?: boolean;
		onFilterChange?: (filters: Record<string, unknown>) => void;
		onPageChange?: (page: number) => void;
		onRefresh?: () => void;
	} = $props();

	// Local copy of the controlled filter map — a writable derived: reads the
	// prop until the toolbar assigns an override; a parent reset (prop change)
	// drops the override, so it always reaches the inputs (same pattern as the
	// generic Table; see workflow.md quirks).
	let localFilters: Record<string, unknown> = $derived({ ...filters });

	/**
	 * Sentinel for the "no filter" option. Bits UI `Combobox` treats `''` as
	 * "no selection", so a plain empty value would break the reset flow.
	 */
	const ALL = '__all__';

	/** Push the edited filter map upwards, dropping empty values. */
	function applyFilters(next: Record<string, unknown>) {
		localFilters = next;
		const out: Record<string, unknown> = {};
		for (const [k, v] of Object.entries(next)) {
			if (v !== '' && v != null) out[k] = v;
		}
		onFilterChange?.(out);
	}

	/** Set one filter; empty string (or the `ALL` sentinel) clears it. */
	function setFilter(key: string, raw: string) {
		applyFilters({ ...localFilters, [key]: raw === ALL ? '' : raw });
	}

	/** Set one text filter from an input event. */
	function setTextFilter(key: string, e: Event) {
		setFilter(key, (e.target as HTMLInputElement).value);
	}

	const STATUSES: IndexStatus[] = ['pending', 'active', 'error', 'dropped'];
	const statusOptions: SelectOption[] = [
		{ value: ALL, label: messages.platform_indexes_filter_all_option() },
		...STATUSES.map((s) => ({ value: s, label: statusLabel(s) }))
	];

	function statusLabel(status: IndexStatus): string {
		switch (status) {
			case 'pending':
				return messages.platform_indexes_status_pending();
			case 'active':
				return messages.platform_indexes_status_active();
			case 'error':
				return messages.platform_indexes_status_error();
			case 'dropped':
				return messages.platform_indexes_status_dropped();
		}
	}

	/** Badge tone per lifecycle status — weak tint paired with full-colour ink. */
	const statusTone: Record<IndexStatus, string> = {
		pending: 'status-info',
		active: 'status-ok',
		error: 'status-danger',
		dropped: 'status-neutral'
	};

	/** Current select value — maps the unset filter back to the `ALL` sentinel. */
	const selectValue = (key: string): string => {
		const v = localFilters[key];
		return v == null || v === '' ? ALL : String(v);
	};

	const textValue = (key: string): string => String(localFilters[key] ?? '');

	const canGoPrev = $derived(page > 1);
	const canGoNext = $derived(items.length === pageSize);

	/** Exact totals shown only when `more` is false; the count is capped at 1000. */
	const countLabel = $derived(
		meta == null
			? ''
			: meta.more
				? messages.platform_indexes_more_records()
				: meta.count === 1
					? messages.platform_indexes_total_count_singular({ count: meta.count })
					: messages.platform_indexes_total_count_plural({ count: meta.count })
	);
</script>

<div class="indexes-table">
	<div class="filter-bar" role="search" aria-label={messages.platform_indexes_page_subtitle()}>
		<div class="filter">
			<Select
				label={messages.platform_indexes_filter_status_label()}
				placeholder={messages.platform_indexes_filter_all_option()}
				searchable={false}
				options={statusOptions}
				value={selectValue('status__eq')}
				onValueChange={(v) => setFilter('status__eq', v)}
			/>
		</div>

		<div class="filter">
			<Input
				label={messages.platform_indexes_filter_domain_label()}
				placeholder={messages.platform_indexes_filter_all_option()}
				value={textValue('domain__match')}
				oninput={(e) => setTextFilter('domain__match', e)}
			/>
		</div>

		<div class="filter">
			<Input
				label={messages.platform_indexes_filter_doctype_label()}
				placeholder={messages.platform_indexes_filter_all_option()}
				value={textValue('doc_type__match')}
				oninput={(e) => setTextFilter('doc_type__match', e)}
			/>
		</div>

		<div class="filter">
			<Input
				label={messages.platform_indexes_filter_field_label()}
				placeholder={messages.platform_indexes_filter_all_option()}
				value={textValue('field_name__match')}
				oninput={(e) => setTextFilter('field_name__match', e)}
			/>
		</div>
	</div>

	{#if error}
		<div class="table-error" role="alert">{error}</div>
	{/if}

	<div class="table-scroll">
		<table>
			<thead>
				<tr>
					<th style="width: 90px">{messages.platform_indexes_col_domain()}</th>
					<th style="width: 130px">{messages.platform_indexes_col_doctype()}</th>
					<th style="width: 1.2fr">{messages.platform_indexes_col_field()}</th>
					<th style="width: 140px">{messages.platform_indexes_col_type()}</th>
					<th style="width: 1.4fr">{messages.platform_indexes_col_index_name()}</th>
					<th style="width: 92px">{messages.platform_indexes_col_status()}</th>
					<th style="width: 1.2fr">{messages.platform_indexes_col_error()}</th>
					<th style="width: 110px">{messages.platform_indexes_col_updated()}</th>
				</tr>
			</thead>
			<tbody>
				{#each items as row (row.id)}
					<tr class="row">
						<td class="mono">{row.domain}</td>
						<td class="mono">{row.doc_type}</td>
						<td class="mono">{row.field_name}</td>
						<td class="mono">{row.index_type}</td>
						<td class="mono" title={row.index_name}>{row.index_name}</td>
						<td>
							<span class={`status-badge ${statusTone[row.status]}`}>{statusLabel(row.status)}</span
							>
						</td>
						<td class="error-cell" title={row.error_message ?? undefined}>
							{row.error_message ?? '—'}
						</td>
						<td><RelativeTime date={row.updated_at} /></td>
					</tr>
				{:else}
					{#if !loading && !error}
						<tr class="row-empty">
							<td colspan="8">{emptyMessage}</td>
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
				{messages.platform_indexes_page_count({ page })}{#if countLabel}&nbsp;· {countLabel}{/if}
			{/if}
		</span>
		<span class="sp"></span>
		<button
			type="button"
			class="refresh-btn"
			disabled={refreshing}
			onclick={() => onRefresh?.()}
			aria-label={messages.platform_indexes_refresh_aria()}
		>
			<RefreshCw size={13} stroke-width={1.9} class={refreshing ? 'spin' : ''} aria-hidden="true" />
			{messages.platform_indexes_refresh()}
		</button>
		<div class="pager">
			<button
				type="button"
				class="pager-btn"
				disabled={!canGoPrev}
				onclick={() => onPageChange?.(page - 1)}
			>
				{messages.platform_indexes_pager_previous()}
			</button>
			<button
				type="button"
				class="pager-btn"
				disabled={!canGoNext}
				onclick={() => onPageChange?.(page + 1)}
			>
				{messages.platform_indexes_pager_next()}
			</button>
		</div>
	</div>
</div>

<style>
	.indexes-table {
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

	/* ── Filter bar ───────────────────────────────────────────────────── */
	.filter-bar {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
		gap: 10px 12px;
	}

	.filter {
		display: flex;
		flex-direction: column;
		gap: 4px;
		min-width: 0;
	}

	.filter :global(.select-label),
	.filter :global(.field-label) {
		font-size: 11px;
		font-weight: 600;
		color: var(--text-3);
		text-transform: uppercase;
		letter-spacing: 0.04em;
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

	.row:hover {
		background: var(--sunken);
	}

	.row-empty td {
		text-align: center;
		color: var(--text-3);
		padding: 24px 10px;
	}

	/* ── Cells ────────────────────────────────────────────────────────── */
	/* Data is mono — identifiers and codes render in the mono face. */
	.mono {
		font-family: var(--font-mono);
		font-size: 12px;
	}

	td.error-cell {
		font-size: 12px;
		color: var(--danger);
		max-width: 220px;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.status-badge {
		display: inline-block;
		padding: 3px 9px;
		border-radius: 999px;
		font-size: 11px;
		font-weight: 600;
		white-space: nowrap;
	}

	/* Weak tint paired with the matching full-colour ink. */
	.status-ok {
		background: var(--ok-weak);
		color: var(--ok);
	}

	.status-info {
		background: var(--info-weak);
		color: var(--info);
	}

	.status-danger {
		background: var(--danger-weak);
		color: var(--danger);
	}

	.status-neutral {
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

	.refresh-btn {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		padding: 6px 12px;
		border: 1px solid var(--border-strong);
		border-radius: var(--r);
		background: var(--surface);
		color: var(--text);
		font-size: 12px;
		font-weight: 600;
		cursor: pointer;
	}

	.refresh-btn:hover:not(:disabled) {
		background: var(--sunken);
	}

	.refresh-btn:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 1px;
	}

	.refresh-btn:disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}

	.refresh-btn :global(.spin) {
		animation: index-refresh-spin 0.9s linear infinite;
	}

	@keyframes index-refresh-spin {
		to {
			transform: rotate(360deg);
		}
	}

	@media (prefers-reduced-motion: reduce) {
		.refresh-btn :global(.spin) {
			animation: none;
		}
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
		outline: 2px solid var(--accent-ink);
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
