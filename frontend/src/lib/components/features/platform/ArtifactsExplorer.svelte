<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import RelativeTime from '$lib/components/primitives/data/RelativeTime.svelte';
	import Capsule from '$lib/components/primitives/data/Capsule.svelte';
	import Select, { type SelectOption } from '$lib/components/primitives/forms/Select.svelte';
	import Input from '$lib/components/primitives/forms/Input.svelte';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import { RefreshCw, Trash2, FileText, Download } from '@lucide/svelte';
	import { artifactDownloadUrl } from '$lib/artifacts.js';
	import {
		formatArtifactSize,
		type ArtifactRow,
		type ArtifactGrantRow,
		type ArtifactReferenceRow
	} from './ArtifactsSource.js';
	import * as messages from '$lib/paraglide/messages';

	/**
	 * Artifact admin explorer — master–detail.
	 *
	 * Left: the artifact list (search + state filter, count columns,
	 * next-page-driven pagination). Right: the detail panel for the selected
	 * artifact — content facts, an open/download link through the cookie-auth
	 * gateway (hidden for tombstones — the mint answers 410 there), the
	 * grants table (with per-grant revoke), the force-delete control (the
	 * `purge *.*` operator action; the parent page owns the confirm flow) and
	 * the "referenced by" table. The parent page owns all state and data
	 * fetching; this component renders and reports intent through callbacks
	 * (same page-owns-state contract as `IndexesTable`).
	 */
	let {
		items = [] as ArtifactRow[],
		loading = false,
		meta = null as { count: number; more: boolean } | null,
		page = 1,
		pageSize = 25,
		filters = {} as Record<string, unknown>,
		refreshing = false,
		selected = null as ArtifactRow | null,
		grants = [] as ArtifactGrantRow[],
		grantsMeta = null as { count: number; more: boolean } | null,
		references = [] as ArtifactReferenceRow[],
		referencesMeta = null as { count: number; more: boolean } | null,
		detailLoading = false,
		detailError = undefined as string | undefined,
		busyGrantId = null as string | null,
		canRevoke = false,
		canPurge = false,
		purging = false,
		driver = undefined as DataDriver | undefined,
		onOpenReference,
		emptyMessage = messages.platform_artifacts_table_empty(),
		onFilterChange,
		onPageChange,
		onRefresh,
		onSelect,
		onRevoke,
		onPurge
	}: {
		/** Artifacts for the current page (already fetched by the parent page). */
		items?: ArtifactRow[];
		loading?: boolean;
		/** Response meta: real capped `count` and `more` flag. `more` means the count was truncated, not that a next page exists. */
		meta?: { count: number; more: boolean } | null;
		page?: number;
		/** Rows requested per page — next-page presence is `items.length === pageSize`. */
		pageSize?: number;
		/** Active filter map (`field__op` → value), owned by the parent page. */
		filters?: Record<string, unknown>;
		/** True while a manual refresh is in flight — the button shows it. */
		refreshing?: boolean;
		/** The selected artifact row, or `null` when nothing is selected. */
		selected?: ArtifactRow | null;
		/** Grants of the selected artifact. */
		grants?: ArtifactGrantRow[];
		grantsMeta?: { count: number; more: boolean } | null;
		/** References of the selected artifact. */
		references?: ArtifactReferenceRow[];
		referencesMeta?: { count: number; more: boolean } | null;
		detailLoading?: boolean;
		detailError?: string;
		/** Grant id currently being revoked (disables that row's button). */
		busyGrantId?: string | null;
		/** Whether the active role holds the `revoke *.*` operator action. */
		canRevoke?: boolean;
		/** Whether the active role holds the `purge *.*` operator action. */
		canPurge?: boolean;
		/** True while a force delete is in flight — the button shows it. */
		purging?: boolean;
		/**
		 * Data driver for the hydrated capsules — the account capsule on the
		 * grants table and the resource capsule on the references table.
		 * Optional so stories can render the bare-text fallbacks.
		 */
		driver?: DataDriver;
		/**
		 * Follow a capsule click to the referenced document (the page wires it
		 * to the QuickViewHost peek drawer, mirroring the audit page).
		 */
		onOpenReference?: (e: { domain: string; doctype: string; id: string }) => void;
		/** Message shown when no artifacts match. */
		emptyMessage?: string;
		onFilterChange?: (filters: Record<string, unknown>) => void;
		onPageChange?: (page: number) => void;
		onRefresh?: () => void;
		onSelect?: (row: ArtifactRow) => void;
		onRevoke?: (grant: ArtifactGrantRow) => void;
		/** Fire the force delete for the selected artifact (the page owns the confirm + API call). */
		onPurge?: (row: ArtifactRow) => void;
	} = $props();

	// Local copy of the controlled filter map — a writable derived: reads the
	// prop until the toolbar assigns an override; a parent reset (prop change)
	// drops the override, so it always reaches the inputs (same pattern as the
	// generic Table; see workflow.md quirks).
	let localFilters: Record<string, unknown> = $derived({ ...filters });

	/** Sentinel for the "no filter" option. Bits UI `Combobox` treats `''` as "no selection". */
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

	const stateOptions: SelectOption[] = [
		{ value: ALL, label: messages.platform_artifacts_filter_state_all() },
		{ value: 'false', label: messages.platform_artifacts_filter_state_live() },
		{ value: 'true', label: messages.platform_artifacts_filter_state_deleted() }
	];

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
				? messages.platform_artifacts_more_records()
				: meta.count === 1
					? messages.platform_artifacts_total_count_singular({ count: meta.count })
					: messages.platform_artifacts_total_count_plural({ count: meta.count })
	);

	function kindLabel(kind: string): string {
		return kind === 'permanent'
			? messages.platform_artifacts_grants_kind_permanent()
			: messages.platform_artifacts_grants_kind_ephemeral();
	}

	function grantExpired(grant: ArtifactGrantRow): boolean {
		return (
			grant.kind === 'ephemeral' &&
			grant.expires_at != null &&
			new Date(grant.expires_at).getTime() < Date.now()
		);
	}

	/** Row label for a reference: the projection display name, else the bare id. */
	function referenceLabel(ref: ArtifactReferenceRow): string {
		return ref.display_name ?? ref.resource_id;
	}

	function referenceTitle(ref: ArtifactReferenceRow): string {
		return ref.display_name ? ref.resource_id : messages.platform_artifacts_references_unresolved();
	}

	/**
	 * Whether a `created_by` value names an account. Grant attribution is
	 * free-form text: account ids (ULIDs and seed slugs), `system`, and the
	 * `app:<app_id>` sentinel. Only the account shape hydrates a capsule.
	 */
	function isAccountRef(value: string): boolean {
		return value.length > 0 && value !== 'system' && !value.startsWith('app:');
	}
</script>

<div class="explorer">
	<div class="list-card">
		<div class="filter-bar" role="search" aria-label={messages.platform_artifacts_page_subtitle()}>
			<div class="filter">
				<Input
					label={messages.platform_artifacts_filter_name_label()}
					placeholder={messages.platform_artifacts_filter_state_all()}
					value={textValue('filename__match')}
					oninput={(e) => setTextFilter('filename__match', e)}
				/>
			</div>
			<div class="filter">
				<Input
					label={messages.platform_artifacts_filter_id_label()}
					placeholder={messages.platform_artifacts_filter_state_all()}
					value={textValue('id__match')}
					oninput={(e) => setTextFilter('id__match', e)}
				/>
			</div>
			<div class="filter">
				<Input
					label={messages.platform_artifacts_filter_mime_label()}
					placeholder={messages.platform_artifacts_filter_state_all()}
					value={textValue('mime_type__match')}
					oninput={(e) => setTextFilter('mime_type__match', e)}
				/>
			</div>
			<div class="filter">
				<Select
					label={messages.platform_artifacts_filter_deleted_label()}
					placeholder={messages.platform_artifacts_filter_state_all()}
					searchable={false}
					options={stateOptions}
					value={selectValue('deleted__eq')}
					onValueChange={(v) => setFilter('deleted__eq', v)}
				/>
			</div>
		</div>

		{#if detailError}
			<div class="table-error" role="alert">{detailError}</div>
		{/if}

		<div class="list-scroll">
			<table>
				<thead>
					<tr>
						<th style="width: 1.6fr">{messages.platform_artifacts_col_file()}</th>
						<th style="width: 120px">{messages.platform_artifacts_col_uploaded_by()}</th>
						<th style="width: 110px">{messages.platform_artifacts_col_mime()}</th>
						<th style="width: 70px">{messages.platform_artifacts_col_size()}</th>
						<th style="width: 56px">{messages.platform_artifacts_col_owners()}</th>
						<th style="width: 70px">{messages.platform_artifacts_col_grants()}</th>
						<th style="width: 82px">{messages.platform_artifacts_col_references()}</th>
						<th style="width: 96px">{messages.platform_artifacts_col_created()}</th>
					</tr>
				</thead>
				<tbody>
					{#each items as row (row.id)}
						<tr
							class="row"
							class:selected={selected?.id === row.id}
							aria-current={selected?.id === row.id ? 'true' : undefined}
						>
							<td>
								<button type="button" class="pick" onclick={() => onSelect?.(row)}>
									<FileText size={14} stroke-width={1.8} aria-hidden="true" />
									<span class="pick-name" title={row.filename}>{row.filename}</span>
									{#if row.deleted_at}
										<span class="deleted-badge">{messages.platform_artifacts_deleted_badge()}</span>
									{/if}
								</button>
							</td>
							<td>
								{#if row.uploaded_by == null}
									<span class="mono">—</span>
								{:else if driver && isAccountRef(row.uploaded_by)}
									<Capsule
										{driver}
										reference={row.uploaded_by}
										qualifiedDoctype="iam.Account"
										label={row.uploaded_by}
										onreferenceclick={onOpenReference}
									/>
								{:else}
									<span class="mono" title={row.uploaded_by}>{row.uploaded_by}</span>
								{/if}
							</td>
							<td class="mono">{row.mime_type}</td>
							<td class="mono">{formatArtifactSize(row.size)}</td>
							<td class="mono">{row.owner_count}</td>
							<td class="mono">{row.grant_count}</td>
							<td class="mono">{row.reference_count}</td>
							<td><RelativeTime date={row.created_at} /></td>
						</tr>
					{:else}
						{#if !loading}
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
					{messages.platform_artifacts_page_count({ page })}{#if countLabel}&nbsp;· {countLabel}{/if}
				{/if}
			</span>
			<span class="sp"></span>
			<button
				type="button"
				class="ghost-btn"
				disabled={refreshing}
				onclick={() => onRefresh?.()}
				aria-label={messages.platform_artifacts_refresh_aria()}
			>
				<RefreshCw
					size={13}
					stroke-width={1.9}
					class={refreshing ? 'spin' : ''}
					aria-hidden="true"
				/>
				{messages.platform_artifacts_refresh()}
			</button>
			<div class="pager">
				<button
					type="button"
					class="ghost-btn"
					disabled={!canGoPrev}
					onclick={() => onPageChange?.(page - 1)}
				>
					{messages.platform_artifacts_pager_previous()}
				</button>
				<button
					type="button"
					class="ghost-btn"
					disabled={!canGoNext}
					onclick={() => onPageChange?.(page + 1)}
				>
					{messages.platform_artifacts_pager_next()}
				</button>
			</div>
		</div>
	</div>

	<div class="detail-card">
		{#if selected}
			<header class="detail-head">
				<div class="detail-title-row">
					<h2 class="detail-name" title={selected.filename}>{selected.filename}</h2>
					{#if selected.deleted_at}
						<span class="deleted-badge">{messages.platform_artifacts_deleted_badge()}</span>
					{/if}
					<div class="detail-actions">
						{#if !selected.deleted_at}
							<!-- The gateway mints on every click; inline MIME types view in
							     the tab, everything else downloads. Tombstones answer 410,
							     so the link hides for them. -->
							<!-- eslint-disable svelte/no-navigation-without-resolve -- the href is the cookie-auth download gateway (a backend route, not a SvelteKit route id); the rule cannot see the model. -->
							<a
								class="dl-link"
								href={artifactDownloadUrl(selected.id)}
								target="_blank"
								rel="noopener noreferrer"
								aria-label={messages.platform_artifacts_download_aria({
									filename: selected.filename
								})}
							>
								<Download size={13} stroke-width={1.8} aria-hidden="true" />
								{messages.platform_artifacts_download()}
							</a>
							<!-- eslint-enable svelte/no-navigation-without-resolve -->
						{/if}
						{#if canPurge}
							<button
								type="button"
								class="danger-btn"
								disabled={purging}
								onclick={() => onPurge?.(selected)}
								aria-label={messages.platform_artifacts_purge_aria({ id: selected.id })}
							>
								<Trash2 size={13} stroke-width={1.8} aria-hidden="true" />
								{purging
									? messages.platform_artifacts_purge_busy()
									: messages.platform_artifacts_purge_button()}
							</button>
						{/if}
					</div>
				</div>
				<dl class="facts">
					<div class="fact fact-wide">
						<dt>{messages.platform_artifacts_id_label()}</dt>
						<dd class="mono sha" title={selected.id}>{selected.id}</dd>
					</div>
					<div class="fact">
						<dt>{messages.platform_artifacts_col_mime()}</dt>
						<dd class="mono">{selected.mime_type}</dd>
					</div>
					<div class="fact">
						<dt>{messages.platform_artifacts_col_size()}</dt>
						<dd class="mono">{formatArtifactSize(selected.size)}</dd>
					</div>
					<div class="fact">
						<dt>{messages.platform_artifacts_col_created()}</dt>
						<dd><RelativeTime date={selected.created_at} /></dd>
					</div>
					<div class="fact">
						<dt>{messages.platform_artifacts_uploaded_by_label()}</dt>
						<dd>
							{#if selected.uploaded_by == null}
								<span class="mono">—</span>
							{:else if driver && isAccountRef(selected.uploaded_by)}
								<Capsule
									{driver}
									reference={selected.uploaded_by}
									qualifiedDoctype="iam.Account"
									label={selected.uploaded_by}
									onreferenceclick={onOpenReference}
								/>
							{:else}
								<span class="mono" title={selected.uploaded_by}>{selected.uploaded_by}</span>
							{/if}
						</dd>
					</div>
					<div class="fact fact-wide">
						<dt>{messages.platform_artifacts_sha256_label()}</dt>
						<dd class="mono sha" title={selected.sha256}>{selected.sha256}</dd>
					</div>
				</dl>
			</header>

			<section class="sub" aria-label={messages.platform_artifacts_grants_title()}>
				<h3>{messages.platform_artifacts_grants_title()}</h3>
				<div class="sub-scroll">
					<table>
						<thead>
							<tr>
								<th style="width: 92px">{messages.platform_artifacts_grants_col_kind()}</th>
								<th style="width: 110px">{messages.platform_artifacts_grants_col_expires()}</th>
								<th style="width: 1.2fr">{messages.platform_artifacts_grants_col_created_by()}</th>
								<th style="width: 110px">{messages.platform_artifacts_grants_col_created()}</th>
								<th style="width: 84px"
									><span class="visually-hidden">{messages.platform_artifacts_revoke_button()}</span
									></th
								>
							</tr>
						</thead>
						<tbody>
							{#each grants as grant (grant.id)}
								<tr class:expired={grantExpired(grant)}>
									<td>
										<span
											class={`kind-badge ${grant.kind === 'permanent' ? 'kind-permanent' : 'kind-ephemeral'}`}
										>
											{kindLabel(grant.kind)}
										</span>
									</td>
									<td>
										{#if grant.kind === 'permanent'}
											{messages.platform_artifacts_grants_never_expires()}
										{:else if grantExpired(grant)}
											<span title={grant.expires_at ?? undefined}>
												{messages.platform_artifacts_grants_expired()}
											</span>
										{:else if grant.expires_at}
											<RelativeTime date={grant.expires_at} />
										{:else}
											—
										{/if}
									</td>
									<td>
										{#if driver && isAccountRef(grant.created_by)}
											<Capsule
												{driver}
												reference={grant.created_by}
												qualifiedDoctype="iam.Account"
												label={grant.created_by}
												onreferenceclick={onOpenReference}
											/>
										{:else}
											<span class="mono" title={grant.created_by}>{grant.created_by}</span>
										{/if}
									</td>
									<td><RelativeTime date={grant.created_at} /></td>
									<td>
										{#if canRevoke}
											<button
												type="button"
												class="danger-btn"
												disabled={busyGrantId === grant.id}
												onclick={() => onRevoke?.(grant)}
												aria-label={messages.platform_artifacts_revoke_aria({ id: grant.id })}
											>
												<Trash2 size={13} stroke-width={1.8} aria-hidden="true" />
												{messages.platform_artifacts_revoke_button()}
											</button>
										{/if}
									</td>
								</tr>
							{:else}
								{#if !detailLoading}
									<tr class="row-empty">
										<td colspan="5">{messages.platform_artifacts_grants_empty()}</td>
									</tr>
								{/if}
							{/each}
						</tbody>
					</table>
				</div>
				{#if grantsMeta?.more}
					<p class="cap-note">{messages.platform_artifacts_more_grants()}</p>
				{/if}
			</section>

			<section class="sub" aria-label={messages.platform_artifacts_references_title()}>
				<h3>{messages.platform_artifacts_references_title()}</h3>
				<div class="sub-scroll">
					<table>
						<thead>
							<tr>
								<th style="width: 1.4fr">{messages.platform_artifacts_references_col_resource()}</th
								>
								<th style="width: 100px">{messages.platform_artifacts_references_col_domain()}</th>
								<th style="width: 110px">{messages.platform_artifacts_references_col_doctype()}</th>
								<th style="width: 1fr">{messages.platform_artifacts_references_col_field()}</th>
								<th style="width: 110px"
									>{messages.platform_artifacts_references_col_last_seen()}</th
								>
							</tr>
						</thead>
						<tbody>
							{#each references as ref (ref.domain + ref.resource_id + ref.resource_field)}
								<tr>
									<td>
										{#if ref.doc_type && driver}
											<!-- Resolvable projection: the capsule hydrates the document's
												display name and follows the click to the peek drawer. -->
											<Capsule
												{driver}
												reference={`${ref.domain}.${ref.doc_type}.${ref.resource_id}`}
												label={ref.resource_id}
												onreferenceclick={onOpenReference}
											/>
										{:else}
											<span class="ref-label" title={referenceTitle(ref)}>
												{referenceLabel(ref)}
											</span>
										{/if}
									</td>
									<td class="mono">{ref.domain}</td>
									<td class="mono">{ref.doc_type ?? '—'}</td>
									<td class="mono">{ref.resource_field}</td>
									<td><RelativeTime date={ref.last_reference_at} /></td>
								</tr>
							{:else}
								{#if !detailLoading}
									<tr class="row-empty">
										<td colspan="5">{messages.platform_artifacts_references_empty()}</td>
									</tr>
								{/if}
							{/each}
						</tbody>
					</table>
				</div>
				{#if referencesMeta?.more}
					<p class="cap-note">{messages.platform_artifacts_more_references()}</p>
				{/if}
			</section>
		{:else}
			<div class="detail-empty">
				<p>{messages.platform_artifacts_detail_empty()}</p>
			</div>
		{/if}
	</div>
</div>

<style>
	.explorer {
		display: grid;
		grid-template-columns: minmax(0, 7fr) minmax(0, 5fr);
		gap: 14px;
		align-items: start;
	}

	.list-card,
	.detail-card {
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: var(--sh-1);
		padding: 16px;
		min-width: 0;
	}

	/* ── List card ───────────────────────────────────────────────────── */
	.filter-bar {
		display: grid;
		grid-template-columns: repeat(auto-fill, minmax(150px, 1fr));
		gap: 10px 12px;
		margin-bottom: 12px;
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

	.list-scroll,
	.sub-scroll {
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

	.row.selected {
		background: var(--accent-weak);
	}

	.row-empty td {
		text-align: center;
		color: var(--text-3);
		padding: 24px 10px;
	}

	/* ── Cells ───────────────────────────────────────────────────────── */
	.mono {
		font-family: var(--font-mono);
		font-size: 12px;
	}

	.pick {
		display: inline-flex;
		align-items: center;
		gap: 7px;
		max-width: 100%;
		padding: 0;
		border: none;
		background: transparent;
		color: var(--text);
		font: inherit;
		font-size: 12.5px;
		cursor: pointer;
		text-align: left;
	}

	.pick:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	.pick-name {
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.deleted-badge {
		flex: none;
		padding: 2px 7px;
		border-radius: 999px;
		background: var(--sunken);
		color: var(--text-2);
		font-size: 10.5px;
		font-weight: 600;
		white-space: nowrap;
	}

	/* ── Footer / pagination ─────────────────────────────────────────── */
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
		margin-top: 12px;
	}

	.foot-info {
		font-size: 12px;
		color: var(--text-3);
	}

	.sp {
		flex: 1;
	}

	.ghost-btn {
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

	.ghost-btn:hover:not(:disabled) {
		background: var(--sunken);
	}

	.ghost-btn:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 1px;
	}

	.ghost-btn:disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}

	.ghost-btn :global(.spin) {
		animation: artifact-refresh-spin 0.9s linear infinite;
	}

	@keyframes artifact-refresh-spin {
		to {
			transform: rotate(360deg);
		}
	}

	@media (prefers-reduced-motion: reduce) {
		.ghost-btn :global(.spin) {
			animation: none;
		}
	}

	.pager {
		display: flex;
		gap: 8px;
	}

	/* ── Detail card ─────────────────────────────────────────────────── */
	.detail-empty {
		display: flex;
		align-items: center;
		justify-content: center;
		min-height: 240px;
	}

	.detail-empty p {
		margin: 0;
		font-size: 13px;
		color: var(--text-3);
	}

	.detail-title-row {
		display: flex;
		align-items: center;
		gap: 10px;
		min-width: 0;
	}

	.detail-actions {
		display: flex;
		align-items: center;
		gap: 8px;
		margin-left: auto;
		flex-shrink: 0;
	}

	.dl-link {
		display: inline-flex;
		align-items: center;
		gap: 5px;
		padding: 5px 10px;
		border: 1px solid var(--border-strong);
		border-radius: var(--r);
		background: var(--surface);
		color: var(--text);
		font-size: 12px;
		font-weight: 600;
		text-decoration: none;
		white-space: nowrap;
		cursor: pointer;
	}

	.dl-link:hover {
		background: var(--sunken);
	}

	.dl-link:focus-visible {
		outline: 2px solid var(--accent);
		outline-offset: 1px;
	}

	.detail-name {
		margin: 0;
		font-size: 15px;
		font-weight: 600;
		color: var(--text);
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.facts {
		display: grid;
		grid-template-columns: 1fr 1fr;
		gap: 8px 18px;
		margin: 14px 0 0;
	}

	.fact dt {
		font-size: 10.5px;
		font-weight: 600;
		color: var(--text-3);
		text-transform: uppercase;
		letter-spacing: 0.04em;
	}

	.fact dd {
		margin: 2px 0 0;
		font-size: 12.5px;
		color: var(--text);
		min-width: 0;
	}

	.fact-wide {
		grid-column: 1 / -1;
	}

	.sha {
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.sub {
		margin-top: 20px;
		min-width: 0;
	}

	.sub h3 {
		margin: 0 0 8px;
		font-size: 12px;
		font-weight: 600;
		color: var(--text-2);
		text-transform: uppercase;
		letter-spacing: 0.04em;
	}

	.kind-badge {
		display: inline-block;
		padding: 3px 9px;
		border-radius: 999px;
		font-size: 11px;
		font-weight: 600;
		white-space: nowrap;
	}

	.kind-permanent {
		background: var(--danger-weak);
		color: var(--danger);
	}

	.kind-ephemeral {
		background: var(--info-weak);
		color: var(--info);
	}

	tr.expired td {
		opacity: 0.55;
	}

	.danger-btn {
		display: inline-flex;
		align-items: center;
		gap: 5px;
		padding: 4px 10px;
		border: 1px solid var(--danger);
		border-radius: var(--r);
		background: var(--surface);
		color: var(--danger);
		font-size: 11.5px;
		font-weight: 600;
		cursor: pointer;
	}

	.danger-btn:hover:not(:disabled) {
		background: var(--danger-weak);
	}

	.danger-btn:focus-visible {
		outline: 2px solid var(--danger);
		outline-offset: 1px;
	}

	.danger-btn:disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}

	.ref-label {
		max-width: 220px;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.cap-note {
		margin: 6px 0 0;
		font-size: 11.5px;
		color: var(--text-3);
	}

	.table-error {
		padding: 10px 12px;
		border-radius: var(--r);
		background: var(--danger-weak);
		color: var(--danger);
		font-size: 13px;
	}

	.visually-hidden {
		position: absolute;
		width: 1px;
		height: 1px;
		overflow: hidden;
		clip: rect(0 0 0 0);
		white-space: nowrap;
	}

	@media (max-width: 1100px) {
		.explorer {
			grid-template-columns: 1fr;
		}
	}

	@media (max-width: 900px) {
		.table-foot {
			flex-direction: column;
			align-items: flex-start;
		}
	}
</style>
