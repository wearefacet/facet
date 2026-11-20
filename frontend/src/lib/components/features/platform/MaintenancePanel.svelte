<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import RelativeTime from '$lib/components/primitives/data/RelativeTime.svelte';
	import ReferencePicker from '$lib/components/primitives/forms/ReferencePicker.svelte';
	import Button from '$lib/components/primitives/actions/Button.svelte';
	import { RefreshCw } from '@lucide/svelte';
	import { DocumentDataDriver } from '$lib/datasource/DocumentDriver.js';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import { confirm } from '$lib/confirm.svelte';
	import type {
		MaintenanceActionKind,
		MaintenanceJobKind,
		MaintenanceJobRow,
		MaintenanceJobStatus,
		MaintenanceJobsResponse,
		MaintenanceStatus
	} from './MaintenanceSource.js';
	import { extractJobStats } from './MaintenanceSource.js';
	import * as messages from '$lib/paraglide/messages';

	let {
		doctype = null as string | null,
		status = null as MaintenanceStatus | null,
		statusLoading = false,
		error = undefined as string | undefined,
		errorStatus = undefined as number | undefined,
		jobs = [] as MaintenanceJobRow[],
		jobsMeta = null as MaintenanceJobsResponse['meta'] | null,
		jobsPage = 1,
		jobsPageSize = 10,
		jobsLoading = false,
		jobsRefreshing = false,
		jobsError = undefined as string | undefined,
		busyKinds = { reproject: false, migrate: false } as Record<MaintenanceActionKind, boolean>,
		actionError = undefined as string | undefined,
		driver = new DocumentDataDriver(''),
		recordMeta,
		onPickDoctype,
		onRetry,
		onEnqueue,
		onJobsRefresh,
		onJobsPageChange
	}: {
		/** The doctype whose status and jobs are shown (committed by the page after a successful load). */
		doctype?: string | null;
		/** Maintenance counters for the committed doctype. */
		status?: MaintenanceStatus | null;
		/** True while the status load is in flight. */
		statusLoading?: boolean;
		/** Page-mapped message for a failed status load — renders the state blocks. */
		error?: string;
		/** HTTP status of the failed load; `403` renders the forbidden message without a retry. */
		errorStatus?: number;
		/** Job rows for the current page (already fetched by the parent page). */
		jobs?: MaintenanceJobRow[];
		/** Response meta of the job list — pagination runs on `more`. */
		jobsMeta?: MaintenanceJobsResponse['meta'] | null;
		jobsPage?: number;
		/** Jobs requested per page — next-page presence is `jobs.length === jobsPageSize`. */
		jobsPageSize?: number;
		/** True while the initial job load is in flight. */
		jobsLoading?: boolean;
		/** True while a manual job refresh is in flight — the button shows it. */
		jobsRefreshing?: boolean;
		/** Message for a failed job load, shown as a banner inside the jobs section. */
		jobsError?: string;
		/** The enqueue calls currently in flight, by action kind. */
		busyKinds?: Record<MaintenanceActionKind, boolean>;
		/** Message for a failed enqueue, shown under the action buttons. */
		actionError?: string;
		/** Data driver for the doctype picker — record search over `core.DocType`. */
		driver?: DataDriver;
		/** Per-record display overrides for the picker — qualified label + own icon/tint. */
		recordMeta?: Record<string, { label?: string; icon?: string | null; color?: string | null }>;
		/** The operator picked a doctype: the id of the picked `core.DocType` document. */
		onPickDoctype?: (doctypeDocId: string) => void;
		/** Retry the failed status load. */
		onRetry?: () => void;
		/** Enqueue a maintenance job after the confirm dialog resolved true. */
		onEnqueue?: (kind: MaintenanceActionKind) => void;
		onJobsRefresh?: () => void;
		onJobsPageChange?: (page: number) => void;
	} = $props();

	/** The picked `core.DocType` document id — the picker's bound value. */
	let pickedId = $state('');

	// Notify the page on a pick (non-empty value); clearing does not re-load.
	// The shadow dedupes: the page passes an inline callback, so the effect
	// must not re-fire when the prop identity changes.
	let notifiedPick: string | null = null;
	$effect(() => {
		const id = pickedId;
		if (!id || id === notifiedPick) return;
		notifiedPick = id;
		onPickDoctype?.(id);
	});

	/**
	 * Open the shared confirm dialog (the global `ConfirmDialog` host renders
	 * it) and only then notify the page. The copy states the audit-log cost
	 * and the low-traffic recommendation — the operator reads it before the
	 * job enters the queue.
	 */
	async function requestEnqueue(kind: MaintenanceActionKind) {
		if (kindBlocked(kind)) return;
		const ok = await confirm({
			title: messages.platform_maintenance_confirm_title(),
			message: messages.platform_maintenance_confirm_body(),
			confirmLabel: messages.platform_maintenance_confirm_run()
		});
		if (!ok) return;
		onEnqueue?.(kind);
	}

	/** The job kind each action enqueues — the key the backend dedupes on. */
	const ACTION_JOB_KIND: Record<MaintenanceActionKind, MaintenanceJobKind> = {
		reproject: 'doctype_reproject',
		migrate: 'doctype_migrate_ahead'
	};

	/** Kinds with a pending or running job — the backend refuses a second of
	 *  the same kind (409); the other kind may run concurrently. */
	const activeJobKinds = $derived(
		new Set(
			jobs
				.filter((row) => row.status === 'pending' || row.status === 'running')
				.map((row) => row.kind)
		)
	);

	/** True when the kind's button must disarm: no committed doctype/status,
	 *  an enqueue of the same kind in flight, or a same-kind job already
	 *  pending/running (the backend answers 409). */
	function kindBlocked(kind: MaintenanceActionKind): boolean {
		return !doctype || !status || busyKinds[kind] || activeJobKinds.has(ACTION_JOB_KIND[kind]);
	}

	const canGoPrev = $derived(jobsPage > 1);
	const canGoNext = $derived(jobs.length === jobsPageSize);

	function kindLabel(kind: MaintenanceJobKind): string {
		return kind === 'doctype_reproject'
			? messages.platform_maintenance_kind_reproject()
			: messages.platform_maintenance_kind_migrate();
	}

	function jobStatusLabel(jobStatus: MaintenanceJobStatus): string {
		switch (jobStatus) {
			case 'pending':
				return messages.platform_maintenance_job_pending();
			case 'running':
				return messages.platform_maintenance_job_running();
			case 'succeeded':
				return messages.platform_maintenance_job_succeeded();
			case 'failed':
				return messages.platform_maintenance_job_failed();
		}
	}

	/** Badge tone per lifecycle status — weak tint paired with full-colour ink. */
	const jobTone: Record<MaintenanceJobStatus, string> = {
		pending: 'status-info',
		running: 'status-info',
		succeeded: 'status-ok',
		failed: 'status-danger'
	};

	/** Compact per-run summary for the Stats cell — `—` when the job has no result yet. */
	function statsLabel(row: MaintenanceJobRow): string {
		const stats = extractJobStats(row);
		if (!stats) return '—';
		if (row.kind === 'doctype_reproject') {
			return messages.platform_maintenance_stats_reproject({
				processed: stats.processed ?? 0,
				superseded: stats.superseded ?? 0,
				skipped: stats.skipped ?? 0,
				failed: stats.failed ?? 0
			});
		}
		return messages.platform_maintenance_stats_migrate({
			migrated: stats.migrated ?? 0,
			superseded: stats.superseded ?? 0,
			skipped: stats.skipped ?? 0,
			failed: stats.failed ?? 0
		});
	}

	/** Fuller breakdown for the Stats cell tooltip: totals, batches, failed ids. */
	function statsTitle(row: MaintenanceJobRow): string | undefined {
		const stats = extractJobStats(row);
		if (!stats) return undefined;
		const parts: string[] = [];
		if (stats.total !== null)
			parts.push(messages.platform_maintenance_stats_total({ count: stats.total }));
		if (stats.batches !== null)
			parts.push(messages.platform_maintenance_stats_batches({ count: stats.batches }));
		if (stats.failedIds.length > 0)
			parts.push(messages.platform_maintenance_stats_failed_ids({ count: stats.failedIds.length }));
		return parts.length > 0 ? parts.join(' · ') : undefined;
	}
</script>

{#if error && errorStatus === 403}
	<div class="state state-error">
		<p>{error}</p>
	</div>
{:else if error}
	<div class="state state-error">
		<p>{error}</p>
		<button class="retry-btn" type="button" onclick={() => onRetry?.()}>
			{messages.common_retry()}
		</button>
	</div>
{:else}
	<div class="maintenance-panel">
		<!-- ── Doctype picker ─────────────────────────────────────────── -->
		<section class="section">
			<div class="doctype-field">
				<ReferencePicker
					label={messages.platform_maintenance_doctype_label()}
					doctype="core.DocType"
					placeholder={messages.platform_maintenance_doctype_placeholder()}
					{driver}
					{recordMeta}
					bind:value={pickedId}
					disabled={statusLoading}
				/>
			</div>

			{#if status}
				<p class="status-line">
					<span>
						{messages.platform_maintenance_status_current_version({
							version: status.current_version
						})}
					</span>
					<span class="dot" aria-hidden="true">·</span>
					<span
						>{messages.platform_maintenance_status_ahead_count({ count: status.ahead_count })}</span
					>
					<span class="dot" aria-hidden="true">·</span>
					<span class:warn={status.blocked_count > 0}>
						{messages.platform_maintenance_status_blocked_count({ count: status.blocked_count })}
					</span>
				</p>
			{:else if statusLoading}
				<p class="hint">{messages.common_loading()}</p>
			{:else}
				<p class="hint">{messages.platform_maintenance_status_empty_hint()}</p>
			{/if}
		</section>

		<!-- ── Actions ────────────────────────────────────────────────── -->
		<section class="section">
			<div class="actions-grid">
				<div class="action">
					<Button
						variant="secondary"
						disabled={kindBlocked('reproject')}
						loading={busyKinds.reproject}
						onclick={() => requestEnqueue('reproject')}
					>
						{messages.platform_maintenance_action_reproject()}
					</Button>
					<p class="action-desc">{messages.platform_maintenance_action_reproject_desc()}</p>
				</div>
				<div class="action">
					<Button
						variant="secondary"
						disabled={kindBlocked('migrate')}
						loading={busyKinds.migrate}
						onclick={() => requestEnqueue('migrate')}
					>
						{messages.platform_maintenance_action_migrate()}
					</Button>
					<p class="action-desc">{messages.platform_maintenance_action_migrate_desc()}</p>
				</div>
			</div>
			{#if actionError}
				<div class="action-error" role="alert">{actionError}</div>
			{/if}
		</section>

		<!-- ── Jobs ───────────────────────────────────────────────────── -->
		<section class="section">
			<h3 class="section-title">{messages.platform_maintenance_jobs_header()}</h3>

			{#if doctype}
				{#if jobsError}
					<div class="table-error" role="alert">{jobsError}</div>
				{/if}

				<div class="table-scroll">
					<table>
						<thead>
							<tr>
								<th style="width: 130px">{messages.platform_maintenance_jobs_col_kind()}</th>
								<th style="width: 100px">{messages.platform_maintenance_jobs_col_status()}</th>
								<th style="width: 110px">{messages.platform_maintenance_jobs_col_started()}</th>
								<th style="width: 110px">{messages.platform_maintenance_jobs_col_updated()}</th>
								<th style="width: 1.2fr">{messages.platform_maintenance_jobs_col_stats()}</th>
								<th style="width: 1.4fr">{messages.platform_maintenance_jobs_col_error()}</th>
							</tr>
						</thead>
						<tbody>
							{#each jobs as row (row.id)}
								<tr class="row">
									<td class="mono">{kindLabel(row.kind)}</td>
									<td>
										<span class={`status-badge ${jobTone[row.status]}`}
											>{jobStatusLabel(row.status)}</span
										>
									</td>
									<td><RelativeTime date={row.created_at} /></td>
									<td><RelativeTime date={row.updated_at} /></td>
									<td class="stats-cell" title={statsTitle(row)}>{statsLabel(row)}</td>
									<td class="error-cell" title={row.last_error ?? undefined}>
										{row.last_error ?? '—'}
									</td>
								</tr>
							{:else}
								{#if !jobsLoading && !jobsError}
									<tr class="row-empty">
										<td colspan="6">{messages.platform_maintenance_jobs_empty()}</td>
									</tr>
								{/if}
							{/each}
						</tbody>
					</table>
				</div>

				{#if jobsLoading && jobs.length === 0}
					<div class="table-loading">{messages.common_loading()}</div>
				{/if}
			{/if}

			<div class="table-foot">
				<span class="foot-info">
					{#if doctype && jobsMeta}
						{messages.platform_maintenance_page_count({ page: jobsPage })}
					{/if}
				</span>
				<span class="sp"></span>
				<button
					type="button"
					class="refresh-btn"
					disabled={jobsRefreshing || !doctype}
					onclick={() => onJobsRefresh?.()}
					aria-label={messages.platform_maintenance_refresh_aria()}
				>
					<RefreshCw
						size={13}
						stroke-width={1.9}
						class={jobsRefreshing ? 'spin' : ''}
						aria-hidden="true"
					/>
					{messages.platform_maintenance_refresh()}
				</button>
				<div class="pager">
					<button
						type="button"
						class="pager-btn"
						disabled={!canGoPrev}
						onclick={() => onJobsPageChange?.(jobsPage - 1)}
					>
						{messages.platform_maintenance_pager_previous()}
					</button>
					<button
						type="button"
						class="pager-btn"
						disabled={!canGoNext}
						onclick={() => onJobsPageChange?.(jobsPage + 1)}
					>
						{messages.platform_maintenance_pager_next()}
					</button>
				</div>
			</div>
		</section>
	</div>
{/if}

<style>
	/* ── Page-level state blocks (403 / load error) ─────────────────────── */
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

	/* ── Card container ── mirrors IndexesTable ─────────────────────────── */
	.maintenance-panel {
		display: flex;
		flex-direction: column;
		gap: 14px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: var(--sh-1);
		padding: 16px;
		min-width: 0;
	}

	.section {
		display: flex;
		flex-direction: column;
		gap: 10px;
		min-width: 0;
	}

	.section + .section {
		border-top: 1px solid var(--border);
		padding-top: 14px;
	}

	.section-title {
		margin: 0;
		font-size: 11.5px;
		font-weight: 600;
		color: var(--text-3);
		text-transform: uppercase;
		letter-spacing: 0.04em;
	}

	/* ── Doctype picker ─────────────────────────────────────────────────── */
	.doctype-field {
		max-width: 480px;
	}

	.hint {
		margin: 0;
		font-size: 12.5px;
		color: var(--text-3);
	}

	/* ── Status summary ─────────────────────────────────────────────────── */
	.status-line {
		margin: 0;
		display: flex;
		flex-wrap: wrap;
		align-items: baseline;
		gap: 8px;
		font-size: 13px;
		color: var(--text-2);
	}

	.status-line .dot {
		color: var(--text-3);
	}

	.status-line .warn {
		color: var(--danger);
	}

	/* ── Actions ────────────────────────────────────────────────────────── */
	.actions-grid {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(240px, 1fr));
		gap: 12px;
	}

	.action {
		display: flex;
		flex-direction: column;
		align-items: flex-start;
		gap: 6px;
	}

	.action-desc {
		margin: 0;
		font-size: 12px;
		color: var(--text-3);
	}

	.action-error {
		padding: 10px 12px;
		border-radius: var(--r);
		background: var(--danger-weak);
		color: var(--danger);
		font-size: 13px;
	}

	/* ── Jobs table ─────────────────────────────────────────────────────── */
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

	/* ── Cells ──────────────────────────────────────────────────────────── */
	/* Data is mono — identifiers and codes render in the mono face. */
	.mono {
		font-family: var(--font-mono);
		font-size: 12px;
	}

	td.stats-cell {
		font-size: 12px;
		color: var(--text-2);
		white-space: nowrap;
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

	/* ── Footer / pagination ────────────────────────────────────────────── */
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
		animation: maintenance-refresh-spin 0.9s linear infinite;
	}

	@keyframes maintenance-refresh-spin {
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

	/* ── Error ──────────────────────────────────────────────────────────── */
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
