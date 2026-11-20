<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" generics="T">
	import { untrack } from 'svelte';
	import type { DocumentRef } from '$lib/datasource/interface.js';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { MutationRecord, HistoryResponse } from '$lib/datasource/types.js';
	import RelativeTime from '$lib/components/primitives/data/RelativeTime.svelte';
	import { actionVariant, describeMutation, hasCause, viaLine } from './auditDiff.js';
	import { errorMessage } from '$lib/datasource/bannerError.js';
	import * as messages from '$lib/paraglide/messages';
	import * as historyDetail from './historyDetail.js';
	import HistoryDetailPane from './HistoryDetailPane.svelte';

	let {
		documentRef,
		selected: selectedProp,
		onRevert,
		onSelect,
		pageSize = 50,
		emptyMessage = messages.audit_history_empty(),
		includeChildren = false,
		parentDocType = null,
		documentLabel = null,
		driver = null
	}: {
		/**
		 * The document reference whose mutation history should be displayed.
		 * `History` calls `documentRef.history()` and, on revert,
		 * `documentRef.rollback()`. Pass `null` to render an empty state.
		 */
		documentRef: DocumentRef<T> | null;
		/**
		 * Controlled selection (ULID of the mutation). Leave undefined for
		 * uncontrolled usage. When set, row clicks are reported through
		 * `onSelect` and the visible selection follows this prop — the page
		 * mirrors it into the URL so a history view is shareable.
		 */
		selected?: string;
		/** Called after a successful rollback with the new mutation id. */
		onRevert?: (result: { mutationId: string; restoredContent: Record<string, unknown> }) => void;
		/** Called whenever the selected mutation changes. */
		onSelect?: (mutation: MutationRecord | null) => void;
		/** Items per page (passed to `history()`). */
		pageSize?: number;
		/** Message shown when the audit trail is empty. */
		emptyMessage?: string;
		/**
		 * Aggregate mode — merge the readable child documents' mutations into
		 * the timeline (backend `?include=children`). Needs `parentDocType` to
		 * tell child rows apart, and `driver` to route their reverts.
		 */
		includeChildren?: boolean;
		/** The doctype of the document `documentRef` points at. */
		parentDocType?: string | null;
		/**
		 * The target document's display label, for the detail header's label
		 * row when the loaded records carry no `display_name` (non-aggregate
		 * mode). The page passes the name its own load resolved.
		 */
		documentLabel?: string | null;
		/**
		 * Data driver used to reach child documents for revert. Child rows
		 * resolve `driver.domain(m.domain).doctype(m.doc_type).doc(m.doc_id)`;
		 * without it the revert button is hidden on child rows.
		 */
		driver?: DataDriver | null;
	} = $props();

	let history = $state<HistoryResponse | null>(null);
	let loading: boolean = $state(true);
	let error: string | undefined = $state(undefined);
	let reverting: boolean = $state(false);
	let revertError: string | undefined = $state(undefined);

	// Internal selection when operating uncontrolled.
	let internalSelected: string | null = $state(null);
	const selectedMutationId = $derived<string | null>(selectedProp ?? internalSelected);

	/** Total pages the deep-link walk may fetch when a shared URL names a
	 * mutation the early pages do not hold. Bounds the link resolution; the
	 * walk only runs while a controlled selection is unsatisfied. */
	const DEEP_LINK_MAX_PAGES = 10;

	const items: MutationRecord[] = $derived(history?.data ?? []);
	const selectedMutation = $derived(items.find((m) => m.id === selectedMutationId) ?? null);

	/** Newest-first ordering means items[0] is the latest mutation. */
	const latestMutationId = $derived(items[0]?.id ?? null);

	// ── Actor labels ────────────────────────────────────────────────────
	//
	// `actioner_id` is a bare account ULID for mutations made by a signed-in
	// account, and a readable principal name (`system`, `system:rollback`, …)
	// for machine callers. The timeline shows the account display name and
	// keeps the raw value otherwise. Labels resolve through the driver with
	// one `iam.Account` show per distinct id; the shared show cache dedupes
	// repeats across rows and reloads. A failed lookup (no grant, unknown id)
	// falls back to the bare id.

	let actorLabels = $state<Record<string, string>>({});
	/** Ids already queued for resolution — plain set, never rendered. */
	const actorsStarted = new Set<string>();
	let actorsDriver: DataDriver | null = null;

	$effect(() => {
		const d = driver;
		if (d !== actorsDriver) {
			// A fresh driver (route reload after a revert) resolves again.
			actorsDriver = d;
			actorsStarted.clear();
			actorLabels = {};
		}
		if (!d) return;
		for (const id of new Set(items.map((m) => m.actioner_id))) {
			if (actorsStarted.has(id)) continue;
			actorsStarted.add(id);
			void historyDetail.resolveActorLabel(d, id).then((label) => {
				if (label) actorLabels[id] = label;
			});
		}
	});

	/** A row belongs to a child document when the aggregate mode is on and
	 * its doctype differs from the parent's. */
	function isChildRow(m: MutationRecord): boolean {
		return historyDetail.isChildRow(m, includeChildren, parentDocType);
	}

	/** Resolved display name for an actioner, or the raw id. */
	function actorLabel(id: string): string {
		return historyDetail.actorLabel(actorLabels, id);
	}

	/** Where the revert of the selected row lands: parent rows revert on the
	 * page's `documentRef`; child rows resolve their own ref through the
	 * driver. `null` hides the revert button. */
	const revertTargetRef: DocumentRef<T> | DocumentRef<Record<string, unknown>> | null = $derived.by(
		() => {
			if (!selectedMutation) return null;
			if (!isChildRow(selectedMutation)) return documentRef;
			if (!driver) return null;
			return driver
				.domain(selectedMutation.domain)
				.doctype(selectedMutation.doc_type)
				.doc(selectedMutation.doc_id);
		}
	);

	const canRevert = $derived(
		!reverting &&
			selectedMutation != null &&
			revertTargetRef != null &&
			selectedMutation.action !== 'snapshot' &&
			selectedMutation.id !== latestMutationId
	);

	let lastNotifiedSelectedId: string | undefined;
	$effect(() => {
		// Sync controlled selection outwards, keyed by mutation id. A reload
		// (deep-link walk, revert) rebuilds the response object, so unchanged
		// records re-wrap in fresh `$state` proxies — an object-identity check
		// would re-fire `onSelect` for an unchanged selection and trip Svelte's
		// `state_proxy_equality_mismatch` warning. The id is the selection's
		// identity here — the same value the URL mirrors as `?mutation=`.
		if (selectedMutation?.id !== lastNotifiedSelectedId) {
			lastNotifiedSelectedId = selectedMutation?.id;
			onSelect?.(selectedMutation);
		}
	});

	async function loadHistory() {
		if (!documentRef) {
			loading = false;
			history = null;
			return;
		}
		loading = true;
		error = undefined;
		try {
			const params = {
				items: pageSize,
				sort: ['-emitted_at'],
				...(includeChildren ? { include: 'children' as const } : {})
			};
			let res = await documentRef.history({ ...params, page: 1 });
			// A full page means more rows may follow — the API's `meta.more`
			// reports a truncated count, not a next page.
			let lastPageSize = res.data.length;
			// Deep link: a shared URL names one mutation (`?mutation=` on the
			// history page). When it is not on the loaded pages, keep fetching
			// older pages until it appears, within a bounded page count.
			// Untracked: a selection made while loading must not re-run the load.
			const wanted = untrack(() => selectedProp);
			let page = 1;
			while (
				wanted != null &&
				lastPageSize === pageSize &&
				page < DEEP_LINK_MAX_PAGES &&
				!res.data.some((m) => m.id === wanted)
			) {
				page += 1;
				const next = await documentRef.history({ ...params, page });
				lastPageSize = next.data.length;
				res = { data: [...res.data, ...next.data], meta: next.meta };
			}
			history = res;
		} catch (e) {
			error = errorMessage(e, messages.audit_history_load_error());
			history = null;
		} finally {
			loading = false;
		}
	}

	// Initial / external load.
	$effect(() => {
		// Re-run if the documentRef identity changes.
		if (!documentRef) {
			loading = false;
			history = null;
			return;
		}
		loadHistory();
	});

	function pick(m: MutationRecord | null) {
		if (selectedProp != null) {
			// Controlled: the parent owns the selection through `selected`, so a
			// click must reach it directly — the sync effect below only fires
			// when the derived selection moves, which a click alone never
			// produces here (the prop shadows the internal id).
			lastNotifiedSelectedId = m?.id;
			onSelect?.(m);
			return;
		}
		internalSelected = m?.id ?? null;
	}

	async function revert() {
		if (!revertTargetRef || !selectedMutation) return;
		reverting = true;
		revertError = undefined;
		try {
			const res = await revertTargetRef.rollback(selectedMutation.id);
			await loadHistory();
			onRevert?.({ mutationId: res.mut_id, restoredContent: res.content });
		} catch (e) {
			revertError = errorMessage(e, messages.audit_rollback_error());
		} finally {
			reverting = false;
		}
	}
</script>

<section class="audit-trail" aria-label={messages.audit_history_aria()}>
	<header class="audit-header">
		<div class="audit-header-title">
			<h2>{messages.audit_history_title()}</h2>
			{#if history}
				<span class="audit-count"
					>{history.meta.count === 1
						? messages.audit_history_count_singular({ count: history.meta.count })
						: messages.audit_history_count_plural({ count: history.meta.count })}</span
				>
			{/if}
		</div>
		<button
			class="audit-refresh"
			type="button"
			onclick={loadHistory}
			disabled={loading}
			title={messages.audit_history_refresh_aria()}
			aria-label={messages.audit_history_refresh_aria()}
		>
			↻
		</button>
	</header>

	<div class="audit-body-pane">
		{#if loading && !history}
			<div class="audit-state">
				<span class="audit-spinner" aria-hidden="true"></span>
				<span>{messages.audit_history_loading()}</span>
			</div>
		{:else if error}
			<div class="audit-state audit-state-error">
				<p>{error}</p>
				<button class="audit-retry" type="button" onclick={loadHistory}>
					{messages.common_retry()}
				</button>
			</div>
		{:else if items.length === 0}
			<div class="audit-state">
				<p>{emptyMessage}</p>
			</div>
		{:else}
			<ol class="audit-timeline" role="list">
				{#each items as m (m.id)}
					{@const variant = actionVariant(m)}
					{@const selected = m.id === selectedMutationId}
					<li>
						<button
							class="audit-row"
							class:audit-row-selected={selected}
							type="button"
							onclick={() => pick(m)}
							aria-pressed={selected ? 'true' : 'false'}
						>
							<span class={`audit-dot audit-dot-${variant.tone}`} aria-hidden="true"></span>
							<span class="audit-body">
								<span class="audit-row-head">
									<span class={`audit-action audit-action-${variant.tone}`}>
										{variant.label}
									</span>
									{#if isChildRow(m)}
										<span
											class="audit-child-badge"
											title={m.display_name ?? historyDetail.childFallbackLabel(m.doc_id)}
										>
											<span class="audit-child-doctype">{m.doc_type}</span>
											<span class="audit-child-label">
												{m.display_name ?? historyDetail.childFallbackLabel(m.doc_id)}
											</span>
										</span>
									{/if}
									<span class="audit-idx">{isChildRow(m) ? `${m.doc_type} ` : ''}#{m.idx}</span>
								</span>
								<span class="audit-summary">{describeMutation(m)}</span>
								<span class="audit-meta">
									<span class="audit-actioner">{actorLabel(m.actioner_id)}</span>
									{#if hasCause(m)}
										{@const via = viaLine(m)}
										<span class="audit-sep">·</span>
										<span class="audit-cause">
											{messages.audit_via({ name: via.label })}{#if via.sub}<span
													class="audit-cause-name"
												>
													· {via.sub}</span
												>{/if}
										</span>
									{/if}
									<span class="audit-sep">·</span>
									<RelativeTime class="audit-time" date={m.emitted_at} />
								</span>
							</span>
						</button>
					</li>
				{/each}
			</ol>

			<HistoryDetailPane
				{selectedMutation}
				{selectedMutationId}
				{actorLabels}
				{includeChildren}
				{parentDocType}
				{documentLabel}
				{driver}
				{latestMutationId}
				hasRevertTarget={revertTargetRef != null}
				{reverting}
				{revertError}
				{canRevert}
				onRevert={revert}
			/>
		{/if}
	</div>
</section>

<style>
	.audit-trail {
		display: flex;
		flex-direction: column;
		min-height: 0;
		height: 100%;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: var(--sh-1);
		overflow: hidden;
	}

	/* ── Header ─────────────────────────────────────────────────────────── */
	.audit-header {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
		padding: 12px 16px;
		border-bottom: 1px solid var(--border);
	}

	.audit-header-title {
		display: flex;
		align-items: baseline;
		gap: 10px;
	}

	.audit-header h2 {
		margin: 0;
		font-family: var(--font-display);
		font-size: 14px;
		font-weight: 600;
		letter-spacing: -0.01em;
		color: var(--text);
	}

	.audit-count {
		font-family: var(--font-mono);
		font-size: 11.5px;
		color: var(--text-2);
	}

	.audit-refresh {
		width: 28px;
		height: 28px;
		display: inline-flex;
		align-items: center;
		justify-content: center;
		border: 1px solid var(--border);
		border-radius: var(--r-sm);
		background: var(--surface);
		color: var(--text-2);
		cursor: pointer;
		font-size: 14px;
		line-height: 1;
	}

	.audit-refresh:hover:not(:disabled) {
		background: var(--surface-2);
		color: var(--text);
		border-color: var(--border-strong);
	}

	.audit-refresh:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	.audit-refresh:disabled {
		opacity: 0.4;
		cursor: not-allowed;
	}

	/* ── Body: timeline + detail pane ──────────────────────────────────── */
	.audit-body-pane {
		flex: 1;
		display: grid;
		grid-template-columns: minmax(240px, 1fr) minmax(0, 1.4fr);
		min-height: 0;
	}

	@media (max-width: 720px) {
		.audit-body-pane {
			grid-template-columns: 1fr;
			grid-template-rows: minmax(160px, 1fr) minmax(0, 1.4fr);
		}
	}

	/* ── Empty / loading / error states ─────────────────────────────────── */
	.audit-state {
		grid-column: 1 / -1;
		display: flex;
		flex-direction: column;
		align-items: center;
		justify-content: center;
		gap: 8px;
		padding: 40px 24px;
		color: var(--text-2);
		font-size: 13px;
		text-align: center;
	}

	.audit-state-error p {
		margin: 0;
		color: var(--danger);
	}

	.audit-retry {
		padding: 5px 12px;
		border: 1px solid var(--border);
		border-radius: var(--r-sm);
		background: var(--surface);
		cursor: pointer;
		font: inherit;
		font-size: 12px;
		color: var(--text);
	}

	.audit-retry:hover {
		background: var(--surface-2);
	}

	/* ── Timeline ───────────────────────────────────────────────────────── */
	.audit-timeline {
		list-style: none;
		margin: 0;
		padding: 8px 0;
		overflow-y: auto;
		min-height: 0;
		border-right: 1px solid var(--border);
	}

	@media (max-width: 720px) {
		.audit-timeline {
			border-right: none;
			border-bottom: 1px solid var(--border);
		}
	}

	.audit-row {
		position: relative;
		display: grid;
		grid-template-columns: 28px 1fr;
		gap: 10px;
		width: 100%;
		padding: 10px 14px 10px 12px;
		border: none;
		background: none;
		cursor: pointer;
		text-align: left;
		font: inherit;
		color: var(--text);
	}

	.audit-row::before {
		/* Vertical timeline rail */
		content: '';
		position: absolute;
		left: 18px;
		top: 0;
		bottom: 0;
		width: 1px;
		background: var(--border);
	}

	.audit-row:first-child::before {
		top: 18px;
	}

	.audit-row:last-child::before {
		bottom: auto;
		height: 18px;
	}

	.audit-row:hover {
		background: var(--surface-2);
	}

	.audit-row-selected {
		background: var(--accent-weak);
	}

	.audit-row-selected::before {
		background: var(--accent);
	}

	.audit-row:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: -2px;
	}

	.audit-dot {
		position: relative;
		z-index: 1;
		width: 10px;
		height: 10px;
		border-radius: 50%;
		margin: 5px 0 0 3px;
		border: 2px solid var(--surface);
		box-shadow: 0 0 0 1px var(--border);
	}

	.audit-row-selected .audit-dot {
		box-shadow: 0 0 0 2px var(--accent);
	}

	.audit-dot-ok {
		background: var(--ok);
	}
	.audit-dot-info {
		background: var(--info);
	}
	.audit-dot-danger {
		background: var(--danger);
	}
	.audit-dot-neutral {
		background: var(--text-3);
	}

	.audit-body {
		display: flex;
		flex-direction: column;
		gap: 3px;
		min-width: 0;
	}

	.audit-row-head {
		display: flex;
		align-items: center;
		gap: 8px;
	}

	.audit-action {
		font-size: 11px;
		font-weight: 600;
		padding: 1px 7px;
		border-radius: var(--r-pill);
		color: var(--text);
	}

	.audit-action-ok {
		color: var(--ok);
		background: var(--ok-weak);
	}
	.audit-action-info {
		color: var(--info);
		background: var(--info-weak);
	}
	.audit-action-danger {
		color: var(--danger);
		background: var(--danger-weak);
	}
	.audit-action-neutral {
		color: var(--text-2);
		background: var(--sunken);
	}

	.audit-idx {
		font-family: var(--font-mono);
		font-size: 10.5px;
		color: var(--text-3);
	}

	.audit-child-badge {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		max-width: 100%;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
		font-size: 10.5px;
		padding: 1px 7px;
		border-radius: var(--r-pill);
		background: var(--sunken);
		color: var(--text-2);
	}

	/* The label is a nested flex item, so the badge's own text-overflow does
	   not reach it — clip here, or a long label pushes the badge wide. */
	.audit-child-label {
		min-width: 0;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.audit-child-doctype {
		font-family: var(--font-mono);
		font-weight: 600;
	}

	.audit-summary {
		font-size: 12.5px;
		color: var(--text);
		line-height: 1.4;
	}

	.audit-meta {
		display: flex;
		align-items: center;
		gap: 6px;
		font-size: 11px;
		color: var(--text-3);
	}

	.audit-actioner {
		font-family: var(--font-mono);
		color: var(--text-2);
	}

	.audit-cause {
		font-size: 10.5px;
		padding: 1px 7px;
		border-radius: var(--r-pill);
		background: var(--sunken);
		color: var(--text-2);
		white-space: nowrap;
	}

	/* The action name inside the via badge — `via facet · confirm`. */
	.audit-cause-name {
		color: var(--text-3);
	}

	.audit-sep {
		opacity: 0.6;
	}

	.audit-time {
		font-family: var(--font-mono);
	}

	.audit-spinner {
		width: 1em;
		height: 1em;
		border: 2px solid currentColor;
		border-right-color: transparent;
		border-radius: 50%;
		animation: audit-spin 0.6s linear infinite;
		flex-shrink: 0;
	}

	@keyframes audit-spin {
		to {
			transform: rotate(360deg);
		}
	}

	@media (prefers-reduced-motion: reduce) {
		.audit-spinner {
			animation-duration: 2s;
		}
	}
</style>
