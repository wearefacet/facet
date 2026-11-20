<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import PageHeader from '$lib/components/primitives/surfaces/PageHeader.svelte';
	import IndexesTable from '$lib/components/features/platform/IndexesTable.svelte';
	import {
		listIndexes,
		IndexesError,
		type IndexListResponse
	} from '$lib/components/features/platform/IndexesSource.js';
	import { errorMessage as toMessage } from '$lib/datasource/bannerError.js';
	import * as m from '$lib/paraglide/messages';

	/**
	 * Managed-index status page (/Configure/platform/indexes).
	 *
	 * The page owns the filter/pagination state and delegates rendering to
	 * `IndexesTable`. Statuses change in background DDL fibers, so the table
	 * is a snapshot: the Refresh button re-fetches on demand.
	 */

	const PAGE_SIZE = 50;

	let filters: Record<string, unknown> = $state({});
	let page: number = $state(1);
	let data = $state<IndexListResponse | null>(null);
	let loading: boolean = $state(true);
	let refreshing: boolean = $state(false);
	let errorMessage: string | undefined = $state(undefined);
	let errorStatus: number | undefined = $state(undefined);

	// Request sequence — a slow response must never overwrite a newer one
	// (per-keystroke text filters can interleave fetches).
	let loadSeq = 0;

	async function load() {
		const my = ++loadSeq;
		loading = true;
		errorMessage = undefined;
		errorStatus = undefined;
		try {
			const res = await listIndexes({ page, items: PAGE_SIZE, filters, sort: ['-updated_at'] });
			if (my !== loadSeq) return;
			data = res;
		} catch (e) {
			if (my !== loadSeq) return;
			data = null;
			if (e instanceof IndexesError) {
				errorStatus = e.status;
				errorMessage = e.status === 403 ? m.platform_indexes_forbidden() : e.message;
			} else {
				errorMessage = toMessage(e, m.platform_indexes_load_error());
			}
		} finally {
			if (my === loadSeq) loading = false;
		}
	}

	// Reload whenever filters or page change (and on mount).
	$effect(() => {
		void filters;
		void page;
		void load();
	});

	async function refresh() {
		refreshing = true;
		try {
			await load();
		} finally {
			refreshing = false;
		}
	}
</script>

<svelte:head>
	<title>{m.platform_indexes_page_title()}</title>
</svelte:head>

<div class="page">
	<PageHeader
		title={m.platform_indexes_page_header()}
		subtitle={m.platform_indexes_page_subtitle()}
	/>

	{#if errorMessage && errorStatus === 403}
		<div class="state state-error">
			<p>{errorMessage}</p>
		</div>
	{:else if errorMessage}
		<div class="state state-error">
			<p>{errorMessage}</p>
			<button class="retry-btn" type="button" onclick={load}>{m.common_retry()}</button>
		</div>
	{:else}
		<IndexesTable
			items={data?.data ?? []}
			{loading}
			error={undefined}
			meta={data?.meta ?? null}
			{page}
			pageSize={PAGE_SIZE}
			{filters}
			{refreshing}
			onFilterChange={(next) => {
				filters = next;
				page = 1;
			}}
			onPageChange={(p) => (page = p)}
			onRefresh={refresh}
		/>
	{/if}
</div>

<style>
	.page {
		padding: 28px 32px 48px;
		max-width: 1280px;
		margin: 0 auto;
	}

	.state {
		padding: 24px;
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		background: var(--surface);
	}

	.state p {
		margin: 0;
		font-size: 13px;
		color: var(--text-2);
	}

	.state-error p {
		color: var(--danger);
	}

	.retry-btn {
		margin-top: 12px;
		padding: 6px 14px;
		border: 1px solid var(--border-strong);
		border-radius: var(--r);
		background: var(--surface);
		color: var(--text);
		font-size: 12.5px;
		font-weight: 600;
		cursor: pointer;
	}

	.retry-btn:hover {
		background: var(--sunken);
	}
</style>
