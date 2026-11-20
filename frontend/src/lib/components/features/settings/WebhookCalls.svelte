<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { ChevronDown, ChevronRight, RotateCcw } from '@lucide/svelte';
	import RelativeTime from '$lib/components/primitives/data/RelativeTime.svelte';
	import {
		listCalls,
		replayCall,
		CALL_STATUSES,
		type CallStatus,
		type WebhookCallRecord
	} from '$lib/webhooks/webhooks.js';
	import { errorMessage } from '$lib/datasource/bannerError.js';
	import * as m from '$lib/paraglide/messages';

	/**
	 * WebhookCalls — the call log for one webhook: one row per outbound
	 * HTTP attempt, newest first, with a status filter, prev/next
	 * pagination on the page size (next-page presence is `calls.length === items`),
	 * an expandable detail row (error text, receiver response snippet), and replay.
	 *
	 * Replay is asynchronous — the backend answers 202 with a fresh job id
	 * and the new attempt appears in the log later — so a replay shows the
	 * "queued" feedback and refreshes the list. Test probes (no `job_id`)
	 * are not replayable and carry no replay button.
	 *
	 * The fetch surface is injectable so stories drive it with canned pages.
	 */

	let {
		webhookId,
		items = 20,
		listFn = listCalls,
		replayFn = replayCall
	}: {
		webhookId: string;
		items?: number;
		listFn?: typeof listCalls;
		replayFn?: typeof replayCall;
	} = $props();

	let calls = $state<WebhookCallRecord[] | null>(null);
	let meta = $state<{ count: number; more: boolean } | null>(null);
	let page = $state(1);
	let statusFilter = $state<CallStatus | ''>('');
	let loadError = $state<string | undefined>(undefined);
	let loading = $state(false);
	let expandedId = $state<string | null>(null);
	let replayingId = $state<string | null>(null);
	let replayQueued = $state<string | null>(null);
	let replayError = $state<string | undefined>(undefined);

	// Initial load + reload on filter / page change. Reads of `statusFilter`
	// and `page` are the dependencies; the fetch effects cannot loop because
	// the writes stay on refs the effect does not read.
	$effect(() => {
		void statusFilter;
		void page;
		void webhookId;
		void load();
	});

	async function load() {
		loading = true;
		loadError = undefined;
		try {
			const res = await listFn(webhookId, {
				page,
				items,
				status: statusFilter === '' ? undefined : statusFilter
			});
			calls = res.data;
			meta = res.meta;
		} catch (e) {
			loadError = errorMessage(e, m.webhooks_calls_load_error());
			calls = null;
			meta = null;
		} finally {
			loading = false;
		}
	}

	function setStatus(next: CallStatus | '') {
		if (statusFilter === next) return;
		statusFilter = next;
		page = 1;
	}

	function toggleExpand(id: string) {
		expandedId = expandedId === id ? null : id;
	}

	async function handleReplay(call: WebhookCallRecord) {
		if (replayingId || call.job_id === null) return;
		replayingId = call.id;
		replayError = undefined;
		replayQueued = null;
		try {
			const res = await replayFn(webhookId, call.id);
			replayQueued = m.webhooks_replay_queued();
			await load();
			// Keep the expanded row on the refreshed list's matching call id —
			// the replayed attempt is a new row, so collapse.
			if (expandedId === res.call_id) expandedId = null;
		} catch (e) {
			replayError = errorMessage(e, m.webhooks_replay_error());
		} finally {
			replayingId = null;
		}
	}

	function resultLabel(call: WebhookCallRecord): string {
		if (call.http_status !== null) return String(call.http_status);
		if (call.error) return call.error;
		return '—';
	}

	function durationLabel(call: WebhookCallRecord): string {
		if (call.duration_ms === null) return '—';
		if (call.duration_ms < 1000) return `${call.duration_ms} ms`;
		return `${(call.duration_ms / 1000).toFixed(1)} s`;
	}
</script>

<div class="calls">
	<div class="toolbar">
		<div class="filters" role="group" aria-label={m.webhooks_calls_filter_aria()}>
			<button
				class="filter-chip"
				class:active={statusFilter === ''}
				aria-pressed={statusFilter === ''}
				onclick={() => setStatus('')}
			>
				{m.webhooks_calls_filter_all()}
			</button>
			{#each CALL_STATUSES as s (s)}
				<button
					class="filter-chip"
					class:active={statusFilter === s}
					aria-pressed={statusFilter === s}
					onclick={() => setStatus(s)}
				>
					{s}
				</button>
			{/each}
		</div>
		{#if meta}
			<span class="count">{m.webhooks_calls_count({ count: meta.count })}</span>
		{/if}
	</div>

	{#if replayQueued}
		<p class="notice" role="status">{replayQueued}</p>
	{/if}
	{#if replayError}
		<p class="alert" role="alert">{replayError}</p>
	{/if}

	{#if loadError}
		<p class="alert" role="alert">{loadError}</p>
	{:else if calls === null && loading}
		<p class="muted">{m.webhooks_loading()}</p>
	{:else if calls !== null && calls.length === 0}
		<p class="muted">{m.webhooks_calls_empty()}</p>
	{:else if calls !== null}
		<ul class="call-list">
			{#each calls as call (call.id)}
				{@const expanded = expandedId === call.id}
				<li class="call-row" class:expanded>
					<button class="row-head" aria-expanded={expanded} onclick={() => toggleExpand(call.id)}>
						<span class="chev">
							{#if expanded}
								<ChevronDown size={14} stroke-width={1.8} />
							{:else}
								<ChevronRight size={14} stroke-width={1.8} />
							{/if}
						</span>
						<span class="when"><RelativeTime date={call.created_at} /></span>
						<span class="event">{call.event}</span>
						<span class="attempt">#{call.attempt}</span>
						<span class="badge badge-{call.status}">{call.status}</span>
						<span class="result" class:err-text={call.status === 'failed'}>{resultLabel(call)}</span
						>
						<span class="duration">{durationLabel(call)}</span>
					</button>
					{#if expanded}
						<div class="detail">
							<dl>
								{#if call.mutation_id}
									<div class="kv">
										<dt>{m.webhooks_calls_mutation_label()}</dt>
										<dd class="mono">{call.mutation_id}</dd>
									</div>
								{/if}
								{#if call.error}
									<div class="kv">
										<dt>{m.webhooks_calls_error_label()}</dt>
										<dd class="mono error-text">{call.error}</dd>
									</div>
								{/if}
								{#if call.response_body}
									<div class="kv">
										<dt>{m.webhooks_calls_response_label()}</dt>
										<dd><pre class="response">{call.response_body}</pre></dd>
									</div>
								{/if}
							</dl>
							{#if call.job_id !== null && call.status !== 'succeeded'}
								<button
									class="replay-btn"
									disabled={replayingId === call.id}
									onclick={() => handleReplay(call)}
								>
									<RotateCcw size={13} stroke-width={1.8} />
									<span
										>{replayingId === call.id
											? m.webhooks_replaying()
											: m.webhooks_replay_button()}</span
									>
								</button>
							{/if}
						</div>
					{/if}
				</li>
			{/each}
		</ul>

		{#if (page > 1 || (calls?.length ?? 0) === items) && !loading}
			<div class="pager">
				<button class="pager-btn" disabled={page <= 1} onclick={() => (page = page - 1)}>
					{m.webhooks_calls_newer()}
				</button>
				<span class="pager-page">{page}</span>
				<button
					class="pager-btn"
					disabled={(calls?.length ?? 0) !== items}
					onclick={() => (page = page + 1)}
				>
					{m.webhooks_calls_older()}
				</button>
			</div>
		{/if}
	{/if}
</div>

<style>
	.calls {
		display: flex;
		flex-direction: column;
		gap: 10px;
	}

	.toolbar {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
		flex-wrap: wrap;
	}

	.filters {
		display: flex;
		gap: 6px;
		flex-wrap: wrap;
	}

	.filter-chip {
		font-size: 11.5px;
		font-weight: 600;
		padding: 4px 10px;
		border-radius: var(--r-pill);
		border: 1px solid var(--border);
		background: var(--surface);
		color: var(--text-2);
		cursor: pointer;
	}

	.filter-chip:hover {
		border-color: var(--border-strong);
	}

	.filter-chip.active {
		background: var(--accent-weak, var(--surface-2));
		border-color: var(--accent);
		color: var(--accent-ink);
	}

	.filter-chip:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 1px;
	}

	.count {
		font-size: 11.5px;
		color: var(--text-3);
	}

	.call-list {
		list-style: none;
		margin: 0;
		padding: 0;
		border-top: 1px solid var(--border);
	}

	.call-row {
		border-bottom: 1px solid var(--border);
	}

	.row-head {
		width: 100%;
		display: grid;
		grid-template-columns: 18px minmax(90px, 130px) minmax(0, 1fr) 34px 84px minmax(60px, 90px) 70px;
		align-items: center;
		gap: 10px;
		padding: 9px 4px;
		background: none;
		border: none;
		cursor: pointer;
		text-align: left;
		font: inherit;
		color: inherit;
	}

	.row-head:hover {
		background: var(--sunken);
	}

	.row-head:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: -2px;
	}

	.chev {
		display: grid;
		place-items: center;
		color: var(--text-3);
	}

	.when {
		font-size: 12px;
		color: var(--text-2);
		white-space: nowrap;
	}

	.event {
		font-family: var(--font-mono);
		font-size: 12px;
		color: var(--text);
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.attempt {
		font-family: var(--font-mono);
		font-size: 11.5px;
		color: var(--text-3);
		text-align: right;
	}

	.badge {
		justify-self: start;
		font-size: 10px;
		font-weight: 700;
		letter-spacing: 0.05em;
		text-transform: uppercase;
		border-radius: var(--r-pill);
		padding: 2px 9px;
	}

	.badge-pending {
		color: var(--warn);
		background: var(--warn-weak);
	}

	.badge-succeeded {
		color: var(--ok);
		background: var(--ok-weak);
	}

	.badge-failed {
		color: var(--danger);
		background: var(--danger-weak);
	}

	.result {
		font-family: var(--font-mono);
		font-size: 12px;
		color: var(--text-2);
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.duration {
		font-family: var(--font-mono);
		font-size: 11.5px;
		color: var(--text-3);
		text-align: right;
	}

	.detail {
		padding: 4px 4px 12px 32px;
		display: flex;
		flex-direction: column;
		gap: 8px;
	}

	.detail dl {
		margin: 0;
		display: flex;
		flex-direction: column;
		gap: 6px;
	}

	.kv {
		display: flex;
		flex-direction: column;
		gap: 2px;
	}

	.kv dt {
		font-size: 10px;
		font-weight: 700;
		letter-spacing: 0.05em;
		text-transform: uppercase;
		color: var(--text-3);
	}

	.kv dd {
		margin: 0;
		font-size: 12px;
		color: var(--text);
	}

	.mono {
		font-family: var(--font-mono);
		font-size: 11.5px;
		word-break: break-all;
	}

	.response {
		margin: 0;
		font-family: var(--font-mono);
		font-size: 11.5px;
		background: var(--sunken);
		border: 1px solid var(--border);
		border-radius: var(--r);
		padding: 8px 10px;
		white-space: pre-wrap;
		word-break: break-word;
		max-height: 160px;
		overflow-y: auto;
	}

	.error-text {
		color: var(--danger);
	}

	.replay-btn {
		align-self: flex-start;
		display: inline-flex;
		align-items: center;
		gap: 6px;
		padding: 5px 10px;
		border-radius: var(--r);
		font-size: 12px;
		font-weight: 600;
		cursor: pointer;
		border: 1px solid var(--border-strong);
		background: var(--surface);
		color: var(--text-2);
	}

	.replay-btn:hover:not(:disabled) {
		border-color: var(--accent);
		color: var(--accent-ink);
		background: var(--surface-2);
	}

	.replay-btn:disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}

	.replay-btn:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 1px;
	}

	.pager {
		display: flex;
		align-items: center;
		justify-content: flex-end;
		gap: 10px;
	}

	.pager-btn {
		font-size: 12px;
		font-weight: 600;
		padding: 5px 12px;
		border-radius: var(--r);
		border: 1px solid var(--border-strong);
		background: var(--surface);
		color: var(--text-2);
		cursor: pointer;
	}

	.pager-btn:disabled {
		opacity: 0.4;
		cursor: not-allowed;
	}

	.pager-btn:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 1px;
	}

	.pager-page {
		font-family: var(--font-mono);
		font-size: 12px;
		color: var(--text-3);
	}

	.notice,
	.alert,
	.muted {
		font-size: 13px;
		margin: 0;
	}

	.notice {
		color: var(--ok);
		background: var(--ok-weak);
		border-radius: var(--r);
		padding: 8px 12px;
	}

	.alert {
		color: var(--danger);
		background: var(--danger-weak);
		border: 1px solid var(--danger);
		border-radius: var(--r);
		padding: 10px 12px;
	}

	.muted {
		color: var(--text-3);
	}

	@media (max-width: 760px) {
		.row-head {
			grid-template-columns: 18px minmax(0, 1fr) 34px 70px;
		}
		.when,
		.duration {
			display: none;
		}
	}
</style>
