<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { Dialog } from 'bits-ui';
	import { X } from '@lucide/svelte';
	import { resolve } from '$app/paths';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { MutationRecord } from '$lib/datasource/types.js';
	import RelativeTime from '$lib/components/primitives/data/RelativeTime.svelte';
	import Capsule from '$lib/components/primitives/data/Capsule.svelte';
	import CopyButton from '$lib/components/primitives/data/CopyButton.svelte';
	import { formatFullDate } from '$lib/utils/relativeTime.js';
	import { displayTimezone } from '$lib/settings.svelte';
	import ChangeList from './ChangeList.svelte';
	import {
		actionVariant,
		mutationChanges,
		isAccountActioner,
		type ChangeEntry
	} from './auditDiff.js';
	import * as historyDetail from './historyDetail.js';
	import * as messages from '$lib/paraglide/messages';

	let {
		selectedMutation,
		selectedMutationId,
		actorLabels,
		includeChildren = false,
		parentDocType = null,
		documentLabel = null,
		driver = null,
		latestMutationId = null,
		hasRevertTarget = false,
		reverting = false,
		revertError,
		canRevert = false,
		onRevert
	}: {
		/** The mutation whose detail renders. `null` shows a placeholder. */
		selectedMutation: MutationRecord | null;
		/** The selected mutation id — picks the "unknown mutation" placeholder. */
		selectedMutationId: string | null;
		/** Actor display names by actioner id. The parent resolves them. */
		actorLabels: Record<string, string>;
		/** Aggregate mode — a child row falls back to a short doc id label. */
		includeChildren?: boolean;
		/** The doctype of the parent document (aggregate mode). */
		parentDocType?: string | null;
		/** The target document's label, for parent rows with no `display_name`. */
		documentLabel?: string | null;
		/** Driver for the actor capsule. */
		driver?: DataDriver | null;
		/** The newest mutation id in the timeline. */
		latestMutationId?: string | null;
		/** Whether the selected row has a revert target. */
		hasRevertTarget?: boolean;
		/** Whether a rollback is running now. */
		reverting?: boolean;
		/** Error from the last revert attempt. */
		revertError?: string;
		/** Whether the revert button is enabled. The parent derives this. */
		canRevert?: boolean;
		/** Runs when the user clicks the revert button; the parent does the rollback. */
		onRevert: () => void;
	} = $props();

	/** Whether the revert confirm dialog is open. The dialog gates the
	 * revert — the same rule the global audit page applies. Cancel closes it
	 * and makes no request; confirm runs the parent's revert flow. */
	let confirmOpen = $state(false);

	// ── Detail header ──────────────────────────────────────────────
	//
	// Four rows, in order: what (action · doctype · label · version),
	// who (actor · via channel/cause), when (full date · relative),
	// ref (mutation id · copy · change stats).

	/** The selected mutation's normalized change list; empty when nothing
	 * is selected. */
	const changes: ChangeEntry[] = $derived(
		selectedMutation ? mutationChanges(selectedMutation) : []
	);

	/** The doctype of the mutation's target — the header's entity cell. */
	const detailEntity = $derived(historyDetail.detailEntity(selectedMutation));

	/** The target document's label: the record's `display_name` when the
	 * response carries one (aggregate mode), else the page-provided label,
	 * else a short doc id. */
	const detailLabel = $derived(
		historyDetail.detailLabel(selectedMutation, includeChildren, parentDocType, documentLabel)
	);

	/** The `via <…>` chip: what actually carried the write. A non-request
	 * cause names the chip (the same rule the timeline badge applies); a
	 * plain request falls through to the auth channel. */
	const viaChip = $derived(historyDetail.viaChip(selectedMutation));

	/** The ref row's change stats: counts per diff operation, `init`
	 * entries (creates, snapshots) counted as `set`. */
	const changeStats = $derived(historyDetail.changeStats(changes));

	/** Resolved display name for an actioner, or the raw id. */
	function actorLabel(id: string): string {
		return historyDetail.actorLabel(actorLabels, id);
	}

	/** The detail pane has no QuickView host — the actor capsule links to the
	 * account's document page instead of opening the peek drawer. */
	function accountHref(id: string): string {
		return resolve('/[domain=notApi]/[doctype]/[id]', {
			domain: 'iam',
			doctype: 'Account',
			id: encodeURIComponent(id)
		});
	}
</script>

<aside class="audit-detail" aria-live="polite">
	{#if selectedMutation}
		{@const variant = actionVariant(selectedMutation)}
		<div class="audit-detail-head">
			<div class="audit-what">
				<span class={`audit-action audit-action-${variant.tone}`}>{variant.label}</span>
				<span class="audit-entity">{detailEntity}</span>
				<span class="audit-label" title={detailLabel}>{detailLabel}</span>
				<span
					class="audit-ver"
					title={messages.audit_detail_version_title({ idx: selectedMutation.idx })}
				>
					v{selectedMutation.idx}
				</span>
			</div>
			<div class="audit-who">
				{#if selectedMutation.actioner_id}
					{#if isAccountActioner(selectedMutation.actioner_id)}
						<Capsule
							driver={driver ?? undefined}
							reference={selectedMutation.actioner_id}
							qualifiedDoctype="iam.Account"
							label={actorLabel(selectedMutation.actioner_id)}
							href={accountHref(selectedMutation.actioner_id)}
						/>
					{:else}
						<code class="audit-detail-actor-plain">{selectedMutation.actioner_id}</code>
					{/if}
				{/if}
				{#if viaChip}
					<span class="audit-sep">{messages.audit_via_sep()}</span>
					{@const ChanIcon = viaChip.icon}
					<span class={`audit-chan audit-chan-${viaChip.tone}`}>
						{#if ChanIcon}<ChanIcon size={12} stroke-width={1.8} aria-hidden="true" />{/if}
						<span class="audit-chan-label">{viaChip.label}</span>
						{#if viaChip.sub}
							<span class="audit-chan-sub">· {viaChip.sub}</span>
						{/if}
					</span>
				{/if}
			</div>
			<div class="audit-when">
				<time
					datetime={selectedMutation.emitted_at}
					title={formatFullDate(selectedMutation.emitted_at, displayTimezone())}
				>
					{formatFullDate(selectedMutation.emitted_at, displayTimezone())}
				</time>
				<span class="audit-sep">·</span>
				<RelativeTime date={selectedMutation.emitted_at} />
			</div>
			<div class="audit-ref">
				<code class="audit-detail-id" title={selectedMutation.id}>
					{selectedMutation.id.slice(0, 16)}…
				</code>
				<CopyButton
					value={selectedMutation.id}
					variant="ghost"
					size="sm"
					title={messages.common_copy_clipboard_aria()}
				/>
				{#if changeStats.length > 0}
					<span class="audit-stats">
						{#each changeStats as s, i (s.kind)}
							{#if i > 0}<span class="audit-sep">·</span>{/if}
							<b class={`audit-stat audit-stat-${s.kind}`}>{s.label}</b>
						{/each}
					</span>
				{/if}
			</div>
		</div>

		{#if changes.length > 0}
			<ChangeList {changes} />
		{:else}
			<p class="audit-detail-empty">{messages.audit_no_changes_recorded()}</p>
		{/if}

		<div class="audit-detail-actions">
			{#if revertError}
				<span class="audit-footer-error">{revertError}</span>
			{/if}
			{#if selectedMutation.id !== latestMutationId && hasRevertTarget}
				{#if selectedMutation.action === 'delete'}
					<span class="audit-restore-hint">{messages.audit_restore_hint()}</span>
				{/if}
				<button
					class="audit-btn-primary"
					type="button"
					onclick={() => (confirmOpen = true)}
					disabled={!canRevert}
					aria-busy={reverting ? 'true' : undefined}
				>
					{#if reverting}
						<span class="audit-spinner" aria-hidden="true"></span>
					{/if}
					{messages.audit_revert_button()}
				</button>
			{/if}
		</div>

		<!-- Revert gate: the confirm dialog names the target document and the
				mutation id, and says that a new snapshot mutation will be written. -->
		<Dialog.Root bind:open={confirmOpen}>
			<Dialog.Portal>
				<Dialog.Overlay class="rv-overlay" />
				<Dialog.Content class="rv-content">
					<Dialog.Title class="rv-title">{messages.audit_confirm_single_title()}</Dialog.Title>
					<Dialog.Description class="rv-desc">
						{#if selectedMutation.action === 'delete'}
							{messages.audit_confirm_delete_desc({
								doctype: `${selectedMutation.domain}.${selectedMutation.doc_type}`,
								doc_id: selectedMutation.doc_id,
								mutation: selectedMutation.id.slice(0, 16) + '…',
								idx: selectedMutation.idx
							})}
						{:else}
							{messages.audit_confirm_update_desc({
								doctype: `${selectedMutation.domain}.${selectedMutation.doc_type}`,
								doc_id: selectedMutation.doc_id,
								mutation: selectedMutation.id.slice(0, 16) + '…',
								idx: selectedMutation.idx
							})}
						{/if}
					</Dialog.Description>
					<div class="rv-actions">
						<Dialog.Close class="rv-cancel">{messages.common_cancel()}</Dialog.Close>
						<button class="rv-confirm" type="button" onclick={onRevert} disabled={reverting}>
							{messages.audit_confirm_rollback_button()}
						</button>
					</div>
					<Dialog.Close class="rv-close" title={messages.common_close()}>
						<X size={16} stroke-width={1.8} />
					</Dialog.Close>
				</Dialog.Content>
			</Dialog.Portal>
		</Dialog.Root>
	{:else if selectedMutationId}
		<div class="audit-detail-placeholder">
			<p>{messages.audit_detail_missing_mutation()}</p>
		</div>
	{:else}
		<div class="audit-detail-placeholder">
			<p>{messages.audit_select_mutation_hint()}</p>
		</div>
	{/if}
</aside>

<style>
	/* ── Shared row pieces (the timeline in History.svelte uses them too) ── */
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

	.audit-sep {
		opacity: 0.6;
	}

	/* ── Detail pane ────────────────────────────────────────────────────── */
	.audit-detail {
		display: flex;
		flex-direction: column;
		min-height: 0;
		overflow-y: auto;
		background: var(--surface);
	}

	/* Detail header — four rows: what / who / when / ref. */
	.audit-detail-head {
		display: flex;
		flex-direction: column;
		gap: 8px;
		padding: 14px 16px 12px;
		border-bottom: 1px solid var(--border);
	}

	/* Row 1 — what: action · doctype · label · version. */
	.audit-what {
		display: flex;
		align-items: center;
		gap: 8px;
		min-width: 0;
	}

	.audit-entity {
		font-family: var(--font-mono);
		font-size: 12px;
		color: var(--text-3);
		flex: none;
	}

	.audit-label {
		font-size: 14px;
		font-weight: 600;
		color: var(--text);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
		min-width: 0;
	}

	.audit-ver {
		margin-left: auto;
		font-family: var(--font-mono);
		font-size: 11.5px;
		color: var(--text-2);
		border: 1px solid var(--border);
		padding: 1px 7px;
		border-radius: var(--r-sm);
		flex: none;
	}

	/* Row 2 — who: actor · via <channel | cause>. */
	.audit-who {
		display: flex;
		align-items: center;
		flex-wrap: wrap;
		gap: 7px;
		font-size: 13px;
		min-width: 0;
	}

	/* The who row's separator is a word, not a dot — the shared 0.6-opacity
	   mute drops it below AA contrast, so it renders at full ink. */
	.audit-who .audit-sep {
		opacity: 1;
		color: var(--text-3);
	}

	.audit-detail-actor-plain {
		font-family: var(--font-mono);
		font-size: 11.5px;
		color: var(--text-2);
	}

	.audit-chan {
		display: inline-flex;
		align-items: center;
		gap: 5px;
		font-family: var(--font-mono);
		font-size: 11.5px;
		padding: 2px 8px;
		border-radius: var(--r-pill);
		border: 1px solid var(--border);
		color: var(--text-2);
		background: var(--surface);
		white-space: nowrap;
	}

	.audit-chan-assistant {
		color: var(--warn);
		background: var(--warn-weak);
		border-color: transparent;
	}

	.audit-chan-cause {
		color: var(--accent-ink);
		background: var(--accent-weak);
		border-color: transparent;
	}

	.audit-chan-label {
		font-weight: 600;
	}

	.audit-chan-sub {
		color: var(--text-3);
		font-weight: 400;
	}

	/* Row 3 — when: full date · relative. */
	.audit-when {
		display: flex;
		align-items: center;
		flex-wrap: wrap;
		gap: 6px;
		font-family: var(--font-mono);
		font-size: 11.5px;
		color: var(--text-2);
	}

	.audit-when time {
		color: var(--text);
	}

	/* RelativeTime ships 12px — match the row's full-date size. */
	.audit-when :global(.relative-time) {
		font-size: 11.5px;
	}

	/* Row 4 — ref: mutation id · copy · change stats. */
	.audit-ref {
		display: flex;
		align-items: center;
		flex-wrap: wrap;
		gap: 6px;
	}

	.audit-detail-id {
		font-family: var(--font-mono);
		font-size: 11px;
		color: var(--text-3);
	}

	.audit-stats {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		font-family: var(--font-mono);
		font-size: 11.5px;
	}

	.audit-stat {
		font-weight: 500;
	}

	.audit-stat-set {
		color: var(--ok);
	}

	.audit-stat-patch {
		color: var(--warn);
	}

	.audit-stat-unset {
		color: var(--danger);
	}

	.audit-stat-redacted {
		color: var(--text-3);
	}

	.audit-detail-empty {
		margin: 0;
		padding: 16px;
		color: var(--text-3);
		font-size: 12.5px;
	}

	.audit-detail-placeholder {
		flex: 1;
		display: flex;
		align-items: center;
		justify-content: center;
		padding: 24px;
	}

	.audit-detail-placeholder p {
		margin: 0;
		color: var(--text-3);
		font-size: 12.5px;
		text-align: center;
	}

	/* ── Detail actions (revert) ────────────────────────────────────────── */
	.audit-detail-actions {
		display: flex;
		align-items: center;
		justify-content: flex-end;
		gap: 8px;
		padding: 10px 16px;
		border-top: 1px solid var(--border);
		background: var(--surface-2);
	}

	.audit-footer-error {
		font-size: 11.5px;
		color: var(--danger);
		margin-right: auto;
	}

	.audit-restore-hint {
		font-size: 11.5px;
		color: var(--text-2);
		margin-right: auto;
	}

	.audit-btn-primary {
		display: inline-flex;
		align-items: center;
		gap: 7px;
		font-family: var(--font-sans);
		font-weight: 600;
		font-size: 12px;
		padding: 6px 11px;
		border-radius: var(--r);
		border: 1px solid var(--border);
		cursor: pointer;
		white-space: nowrap;
	}

	.audit-btn-primary {
		background: var(--accent);
		color: var(--on-accent);
		border-color: var(--accent);
	}

	.audit-btn-primary:hover:not(:disabled) {
		background: var(--accent-press);
		border-color: var(--accent-press);
	}

	.audit-btn-primary:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	.audit-btn-primary:disabled {
		opacity: 0.45;
		pointer-events: none;
	}

	/* Spinner — the loading state in History.svelte carries its own copy. */
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

	/* ── Revert confirm dialog (portalled — Bits UI renders these elements) ── */
	:global(.rv-overlay) {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.45);
		z-index: 120;
	}

	:global(.rv-content) {
		position: fixed;
		top: 50%;
		left: 50%;
		transform: translate(-50%, -50%);
		width: min(440px, 90vw);
		display: flex;
		flex-direction: column;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: var(--sh-2);
		z-index: 121;
		padding: 24px;
		gap: 16px;
	}

	:global(.rv-title) {
		font-family: var(--font-display);
		font-size: 16px;
		font-weight: 600;
		margin: 0;
	}

	:global(.rv-desc) {
		font-size: 13px;
		color: var(--text-2);
		margin: 0;
		line-height: 1.5;
	}

	:global(.rv-content .rv-actions) {
		display: flex;
		justify-content: flex-end;
		gap: 8px;
	}

	:global(.rv-content .rv-cancel),
	:global(.rv-content .rv-confirm) {
		padding: 6px 14px;
		border-radius: var(--r);
		font-size: 12.5px;
		font-weight: 600;
		cursor: pointer;
	}

	:global(.rv-content .rv-cancel) {
		border: 1px solid var(--border-strong);
		background: var(--surface);
		color: var(--text);
	}

	:global(.rv-content .rv-cancel:hover) {
		background: var(--sunken);
	}

	:global(.rv-content .rv-confirm) {
		border: 1px solid var(--danger);
		background: var(--danger);
		color: #ffffff;
	}

	:global(.rv-content .rv-confirm:disabled) {
		opacity: 0.5;
		cursor: not-allowed;
	}

	:global(.rv-content .rv-close) {
		position: absolute;
		top: 14px;
		right: 14px;
		width: 28px;
		height: 28px;
		display: grid;
		place-items: center;
		border: none;
		border-radius: var(--r);
		background: none;
		color: var(--text-3);
		cursor: pointer;
	}

	:global(.rv-content .rv-close:hover) {
		background: var(--sunken);
		color: var(--text);
	}
</style>
