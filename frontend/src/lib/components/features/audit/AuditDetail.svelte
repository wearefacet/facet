<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { Dialog } from 'bits-ui';
	import { untrack } from 'svelte';
	import { X } from '@lucide/svelte';
	import { formatFullDate } from '$lib/utils/relativeTime.js';
	import { displayTimezone } from '$lib/settings.svelte';
	import ChangeList from './ChangeList.svelte';
	import Capsule from '$lib/components/primitives/data/Capsule.svelte';
	import {
		actionVariant,
		mutationChanges,
		hasCause,
		humanizeLabel,
		parseCauseSource,
		channelLabel,
		isAccountActioner,
		type ChangeEntry
	} from './auditDiff.js';
	import type { MutationRecord } from '$lib/datasource/types.js';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import { resolve } from '$app/paths';
	import { SvelteMap } from 'svelte/reactivity';
	import * as messages from '$lib/paraglide/messages';

	let {
		/** The mutation to inspect. `null` renders the placeholder state. */
		mutation = null as MutationRecord | null,
		/** UI hint only — the backend re-checks. Computed by the page from the permission manifest. */
		canRollback = false,
		/** Human-readable reason the rollback button is disabled (delete target, newest mutation, …). */
		rollBlockReason = '',
		/** True while the rollback request is in flight. */
		rollingBack = false,
		/** Error message from a failed rollback, shown inline. */
		rollbackError = undefined as string | undefined,
		/** Called when the user confirms the rollback in the dialog. */
		onRollback,
		/** Opens the mutation's document in the QuickView peek drawer. */
		onOpenDocument,
		/** Follows a cause's source-document capsule (`cause_source`). */
		onOpenSource,
		/** Driver for hydrating the actor capsule (account display name). */
		driver = undefined as DataDriver | undefined,
		/** Opens the mutation's actor account in the QuickView peek drawer. */
		onOpenActor,
		/** The mutation's causal cluster (all mutations sharing its `cause_trace`). */
		cluster = [] as MutationRecord[],
		/** True while the cluster fetch is in flight. */
		clusterLoading = false,
		/** True while the cluster rollback request is in flight. */
		rollingBackCluster = false,
		/** Called when the user confirms the whole-action rollback in the dialog. */
		onRollbackCluster,
		/** `app.App` projection id → display-name map, for the metadata row. */
		appNames = {} as Record<string, string>
	}: {
		mutation?: MutationRecord | null;
		canRollback?: boolean;
		rollBlockReason?: string;
		rollingBack?: boolean;
		rollbackError?: string;
		onRollback?: (mutation: MutationRecord) => void;
		onOpenDocument?: (mutation: MutationRecord) => void;
		onOpenSource?: (e: { domain: string; doctype: string; id: string }) => void;
		driver?: DataDriver;
		onOpenActor?: (e: { domain: string; doctype: string; id: string }) => void;
		cluster?: MutationRecord[];
		clusterLoading?: boolean;
		rollingBackCluster?: boolean;
		onRollbackCluster?: () => void;
		appNames?: Record<string, string>;
	} = $props();

	const changes: ChangeEntry[] = $derived(mutation ? mutationChanges(mutation) : []);
	const isDelete = $derived(mutation?.action === 'delete');

	/** The document the cause ran on, parsed from `cause_source`. */
	const causeSource = $derived(
		mutation?.cause_source ? parseCauseSource(mutation.cause_source) : null
	);

	/** Cluster documents grouped by doc id, with per-document change counts. */
	const clusterDocs = $derived.by(() => {
		// untrack: interleaved get/set on a tracked map inside a derivation
		// self-dirties it and re-runs the derivation.
		return untrack(() => {
			const byDoc = new SvelteMap<
				string,
				{ domain: string; doc_type: string; doc_id: string; count: number }
			>();
			for (const m of cluster) {
				const entry = byDoc.get(m.doc_id);
				if (entry) {
					entry.count += 1;
				} else {
					byDoc.set(m.doc_id, {
						domain: m.domain,
						doc_type: m.doc_type,
						doc_id: m.doc_id,
						count: 1
					});
				}
			}
			return [...byDoc.values()];
		});
	});
	/** True when the mutation carries cause info or sits in a multi-document cluster. */
	const showCause = $derived(!!mutation && (hasCause(mutation) || clusterDocs.length > 1));

	let confirmOpen = $state(false);
	let confirmMode = $state<'single' | 'cluster'>('single');

	function confirmRollback() {
		if (!mutation) return;
		if (confirmMode === 'cluster') {
			onRollbackCluster?.();
		} else {
			onRollback?.(mutation);
		}
	}
</script>

<aside class="audit-detail" aria-live="polite">
	{#if mutation}
		{@const variant = actionVariant(mutation)}
		<div class="detail-head">
			<span class={`action-badge action-${variant.tone}`}>{variant.label}</span>
			<span class="detail-idx">#{mutation.idx}</span>
			<code class="detail-id" title={mutation.id}>{mutation.id.slice(0, 16)}…</code>
		</div>
		<p class="detail-target">
			{messages.audit_detail_target_label()}
			{#if onOpenDocument}
				<button
					type="button"
					class="doc-link doc-link-btn"
					onclick={() => onOpenDocument?.(mutation)}
				>
					{mutation.domain}.{mutation.doc_type}
				</button>
			{:else}
				<a
					class="doc-link"
					href={resolve('/[domain=notApi]/[doctype]/[id]', {
						domain: mutation.domain,
						doctype: mutation.doc_type,
						id: mutation.doc_id
					})}>{mutation.domain}.{mutation.doc_type}</a
				>
			{/if}
		</p>
		{#if mutation.actioner_id}
			<p class="detail-actor">
				{messages.audit_detail_actor_label()}
				{#if isAccountActioner(mutation.actioner_id)}
					<Capsule
						{driver}
						reference={mutation.actioner_id}
						qualifiedDoctype="iam.Account"
						label={mutation.actioner_id}
						onreferenceclick={onOpenActor}
					/>
				{:else}
					<code class="actor-plain">{mutation.actioner_id}</code>
				{/if}
			</p>
		{/if}
		{#if mutation.channel || mutation.app}
			<p class="detail-source">
				{#if mutation.channel}{messages.audit_via({
						name: channelLabel(mutation.channel)
					})}{/if}{#if mutation.app}
					{mutation.channel ? ' · ' : ''}{messages.audit_via({
						name: appNames[mutation.app] ?? mutation.app
					})}{/if}
			</p>
		{/if}
		<p class="detail-date" title={formatFullDate(mutation.emitted_at, displayTimezone())}>
			{formatFullDate(mutation.emitted_at, displayTimezone())}
		</p>

		{#if showCause && mutation}
			<div class="detail-cause">
				<div class="cause-row">
					<span class="cause-kind">{humanizeLabel(mutation.cause_kind)}</span>
					{#if mutation.cause_name}
						<span class="cause-name">{mutation.cause_name}</span>
					{/if}
				</div>
				{#if causeSource && onOpenSource}
					<div class="cause-row">
						<span class="cause-label">{messages.audit_cause_on_label()}</span>
						<button
							type="button"
							class="doc-link doc-link-btn"
							onclick={() => onOpenSource?.(causeSource)}
						>
							{causeSource.domain}.{causeSource.doctype}
						</button>
						<code class="cause-id" title={causeSource.id}>{causeSource.id}</code>
					</div>
				{/if}
				{#if clusterDocs.length > 1}
					<div class="cause-cluster">
						<p class="cause-cluster-title">
							{cluster.length === 1
								? messages.audit_cluster_title_singular({
										changes: cluster.length,
										documents: clusterDocs.length
									})
								: messages.audit_cluster_title_plural({
										changes: cluster.length,
										documents: clusterDocs.length
									})}
						</p>
						{#if clusterLoading}
							<p class="cause-cluster-note">{messages.audit_cluster_loading()}</p>
						{:else}
							<ul class="cluster-list">
								{#each clusterDocs as d (d.doc_id)}
									<li>
										<span class="cluster-doc">{d.domain}.{d.doc_type}</span>
										<code class="cluster-id" title={d.doc_id}>{d.doc_id}</code>
										<span class="cluster-count">×{d.count}</span>
									</li>
								{/each}
							</ul>
						{/if}
					</div>
				{/if}
			</div>
		{/if}

		{#if changes.length > 0}
			<ChangeList {changes} layout="stacked" />
		{:else if !showCause}
			<p class="detail-empty">{messages.audit_no_changes_recorded()}</p>
		{/if}

		<div class="detail-actions">
			{#if rollbackError}
				<span class="rollback-error" role="alert">{rollbackError}</span>
			{/if}
			<button
				class="rollback-btn"
				type="button"
				disabled={!canRollback || rollingBack || rollingBackCluster}
				title={rollBlockReason ||
					(isDelete ? messages.audit_restore_title() : messages.audit_rollback_button())}
				aria-busy={rollingBack ? 'true' : undefined}
				onclick={() => {
					confirmMode = 'single';
					confirmOpen = true;
				}}
			>
				{#if rollingBack}
					<span class="spinner" aria-hidden="true"></span>
				{/if}
				{isDelete ? messages.audit_restore_button() : messages.audit_rollback_button()}
			</button>
			{#if showCause && clusterDocs.length > 1 && onRollbackCluster}
				<button
					class="cluster-btn"
					type="button"
					disabled={!canRollback || rollingBack || rollingBackCluster}
					title={messages.audit_cluster_button_title()}
					aria-busy={rollingBackCluster ? 'true' : undefined}
					onclick={() => {
						confirmMode = 'cluster';
						confirmOpen = true;
					}}
				>
					{#if rollingBackCluster}
						<span class="spinner spinner-dark" aria-hidden="true"></span>
					{/if}
					{messages.audit_cluster_button({
						changes: cluster.length,
						documents: clusterDocs.length
					})}
				</button>
			{/if}
			{#if rollBlockReason}
				<p class="block-reason">{rollBlockReason}</p>
			{/if}
		</div>

		<Dialog.Root bind:open={confirmOpen}>
			<Dialog.Portal>
				<Dialog.Overlay class="rb-overlay" />
				<Dialog.Content class="rb-content">
					<Dialog.Title class="rb-title">
						{confirmMode === 'cluster'
							? messages.audit_confirm_cluster_title()
							: messages.audit_confirm_single_title()}
					</Dialog.Title>
					{#if confirmMode === 'cluster' && mutation}
						<Dialog.Description class="rb-desc">
							{cluster.length === 1
								? messages.audit_confirm_cluster_desc_singular({
										changes: cluster.length,
										documents: clusterDocs.length
									})
								: messages.audit_confirm_cluster_desc_plural({
										changes: cluster.length,
										documents: clusterDocs.length
									})}
						</Dialog.Description>
						<ul class="rb-docs">
							{#each clusterDocs as d (d.doc_id)}
								<li>
									<span>{d.domain}.{d.doc_type}</span>
									<code title={d.doc_id}>{d.doc_id}</code>
								</li>
							{/each}
						</ul>
					{:else if mutation}
						<Dialog.Description class="rb-desc">
							{#if isDelete}
								{messages.audit_confirm_delete_desc({
									doctype: `${mutation.domain}.${mutation.doc_type}`,
									doc_id: mutation.doc_id,
									mutation: mutation.id.slice(0, 16) + '…',
									idx: mutation.idx
								})}
							{:else}
								{messages.audit_confirm_update_desc({
									doctype: `${mutation.domain}.${mutation.doc_type}`,
									doc_id: mutation.doc_id,
									mutation: mutation.id.slice(0, 16) + '…',
									idx: mutation.idx
								})}
							{/if}
						</Dialog.Description>
					{/if}
					<div class="rb-actions">
						<Dialog.Close class="rb-cancel">{messages.common_cancel()}</Dialog.Close>
						<button
							class="rb-confirm"
							type="button"
							onclick={confirmRollback}
							disabled={rollingBack || rollingBackCluster}
						>
							{confirmMode === 'cluster'
								? messages.audit_confirm_cluster_button()
								: messages.audit_confirm_rollback_button()}
						</button>
					</div>
					<Dialog.Close class="rb-close" title={messages.common_close()}>
						<X size={16} stroke-width={1.8} />
					</Dialog.Close>
				</Dialog.Content>
			</Dialog.Portal>
		</Dialog.Root>
	{:else}
		<div class="detail-placeholder">
			<p>{messages.audit_select_mutation_hint()}</p>
		</div>
	{/if}
</aside>

<style>
	.audit-detail {
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: var(--sh-1);
		padding: 20px;
		font-size: 13px;
		color: var(--text);
		min-width: 0;
		/* Stay visible while the table scrolls; long change lists scroll
		   inside the panel instead of overflowing the viewport. */
		position: sticky;
		top: 16px;
		max-height: calc(100vh - 32px);
		overflow-y: auto;
	}

	.detail-head {
		display: flex;
		align-items: center;
		gap: 8px;
		flex-wrap: wrap;
	}

	.detail-idx {
		font-family: var(--font-mono);
		font-size: 12px;
		color: var(--text-3);
	}

	.detail-id {
		font-family: var(--font-mono);
		font-size: 11.5px;
		color: var(--text-3);
	}

	.detail-target {
		margin: 10px 0 0;
		font-size: 12.5px;
		color: var(--text-2);
	}

	.doc-link {
		font-family: var(--font-mono);
		color: var(--accent-ink);
		text-decoration: none;
	}

	.doc-link-btn {
		border: none;
		background: none;
		padding: 0;
		cursor: pointer;
		font-size: inherit;
	}

	.doc-link:hover {
		text-decoration: underline;
	}

	.detail-actor {
		margin: 8px 0 0;
		font-size: 12.5px;
		color: var(--text-2);
		display: flex;
		align-items: center;
		gap: 6px;
		flex-wrap: wrap;
	}

	.actor-plain {
		font-family: var(--font-mono);
		font-size: 11.5px;
		color: var(--text-2);
	}

	.detail-source {
		margin: 6px 0 0;
		font-family: var(--font-mono);
		font-size: 11.5px;
		color: var(--text-3);
	}

	.detail-date {
		color: var(--text-3);
		font-size: 12px;
	}

	.detail-empty {
		margin: 16px 0 0;
		font-size: 12.5px;
		color: var(--text-3);
	}

	/* ── Cause provenance ─────────────────────────────────────────── */
	.detail-cause {
		margin: 12px 0 0;
		padding: 10px 12px;
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--sunken);
		display: flex;
		flex-direction: column;
		gap: 6px;
	}

	.cause-row {
		display: flex;
		align-items: center;
		gap: 6px;
		flex-wrap: wrap;
		min-width: 0;
	}

	.cause-kind {
		font-size: 10.5px;
		font-weight: 600;
		padding: 1px 6px;
		border-radius: 999px;
		background: var(--accent-weak);
		color: var(--accent-ink);
	}

	.cause-name {
		font-family: var(--font-mono);
		font-size: 12px;
		color: var(--text);
	}

	.cause-event {
		font-size: 11.5px;
		color: var(--text-3);
	}

	.cause-label {
		font-size: 11.5px;
		color: var(--text-3);
	}

	.cause-id {
		font-family: var(--font-mono);
		font-size: 11px;
		color: var(--text-3);
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
		min-width: 0;
	}

	.cause-cluster-title {
		margin: 0;
		font-size: 11.5px;
		font-weight: 600;
		color: var(--text-2);
	}

	.cause-cluster-note {
		margin: 0;
		font-size: 11.5px;
		color: var(--text-3);
	}

	.cluster-list {
		margin: 4px 0 0;
		padding: 0;
		list-style: none;
		display: flex;
		flex-direction: column;
		gap: 4px;
		max-height: 160px;
		overflow-y: auto;
	}

	.cluster-list li {
		display: flex;
		align-items: baseline;
		gap: 6px;
		font-size: 11.5px;
		min-width: 0;
	}

	.cluster-doc {
		font-family: var(--font-mono);
		color: var(--text);
		flex-shrink: 0;
	}

	.cluster-id {
		font-family: var(--font-mono);
		color: var(--text-3);
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
		min-width: 0;
	}

	.cluster-count {
		margin-left: auto;
		font-family: var(--font-mono);
		color: var(--text-3);
	}

	.cluster-btn {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		gap: 8px;
		padding: 8px 14px;
		border: 1px solid var(--border-strong);
		background: var(--surface);
		color: var(--text);
		border-radius: var(--r);
		font-size: 12.5px;
		font-weight: 600;
		cursor: pointer;
	}

	.cluster-btn:hover:not(:disabled) {
		background: var(--sunken);
	}

	.cluster-btn:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	.cluster-btn:disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}

	.spinner-dark {
		border-color: var(--text-2);
		border-top-color: transparent;
	}

	.detail-actions {
		margin-top: 16px;
		display: flex;
		flex-direction: column;
		gap: 8px;
	}

	.rollback-btn {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		gap: 8px;
		padding: 8px 14px;
		border: 1px solid var(--accent);
		background: var(--accent);
		/* Gold fill carries dark text — `--accent-ink` is gold-on-light and
		   invisible on a gold fill (see tokens: "Gold fill ≠ gold text"). */
		color: var(--on-accent);
		border-radius: var(--r);
		font-size: 12.5px;
		font-weight: 600;
		cursor: pointer;
	}

	.rollback-btn:hover:not(:disabled) {
		filter: brightness(0.97);
	}

	.rollback-btn:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	.rollback-btn:disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}

	.block-reason {
		margin: 0;
		font-size: 11.5px;
		color: var(--text-3);
	}

	.rollback-error {
		color: var(--danger);
		font-size: 12px;
	}

	.spinner {
		width: 14px;
		height: 14px;
		border: 2px solid var(--on-accent);
		border-top-color: transparent;
		border-radius: 50%;
		animation: spin 0.8s linear infinite;
	}

	@keyframes spin {
		to {
			transform: rotate(360deg);
		}
	}

	@media (prefers-reduced-motion: reduce) {
		.spinner {
			animation: none;
		}
	}

	.detail-placeholder {
		display: flex;
		align-items: center;
		justify-content: center;
		min-height: 180px;
	}

	.detail-placeholder p {
		font-size: 12.5px;
		color: var(--text-3);
		margin: 0;
	}

	/* ── Confirm dialog ─────────────────────────────────────────────── */
	:global(.rb-overlay) {
		position: fixed;
		inset: 0;
		background: rgba(0, 0, 0, 0.45);
		z-index: 100;
	}

	:global(.rb-content) {
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
		z-index: 101;
		padding: 24px;
		gap: 16px;
	}

	:global(.rb-title) {
		font-family: var(--font-display);
		font-size: 16px;
		font-weight: 600;
		margin: 0;
	}

	:global(.rb-desc) {
		font-size: 13px;
		color: var(--text-2);
		margin: 0;
		line-height: 1.5;
	}

	.rb-actions {
		display: flex;
		justify-content: flex-end;
		gap: 8px;
	}

	.rb-docs {
		margin: 0;
		padding: 8px 12px;
		list-style: none;
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--sunken);
		display: flex;
		flex-direction: column;
		gap: 4px;
		max-height: 180px;
		overflow-y: auto;
		font-size: 12px;
	}

	.rb-docs li {
		display: flex;
		align-items: baseline;
		gap: 8px;
		min-width: 0;
	}

	.rb-docs code {
		font-family: var(--font-mono);
		font-size: 11px;
		color: var(--text-3);
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
		min-width: 0;
	}

	.rb-cancel,
	.rb-confirm {
		padding: 6px 14px;
		border-radius: var(--r);
		font-size: 12.5px;
		font-weight: 600;
		cursor: pointer;
	}

	.rb-cancel {
		border: 1px solid var(--border-strong);
		background: var(--surface);
		color: var(--text);
	}

	.rb-cancel:hover {
		background: var(--sunken);
	}

	.rb-confirm {
		border: 1px solid var(--danger);
		background: var(--danger);
		color: #ffffff;
	}

	.rb-confirm:disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}

	:global(.rb-content .rb-close) {
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

	:global(.rb-content .rb-close:hover) {
		background: var(--sunken);
		color: var(--text);
	}
</style>
