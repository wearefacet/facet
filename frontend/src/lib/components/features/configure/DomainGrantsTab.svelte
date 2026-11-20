<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	/**
	 * Grants pane of the domain editor — the domain's cross-domain
	 * data-sharing contracts, split by side.
	 *
	 * **Issued grants** — `core.DomainGrant` documents filed under this
	 * domain (the producer). The producer shapes the `resources` list
	 * (its own doctypes + field tags) and accepts or pauses each contract
	 * through the activate/deactivate routes.
	 *
	 * **Held access** — grants filed under other domains that name this
	 * domain as `consumer_domain`, read through the reference's equality
	 * filter. Read-only: the producer owns the document, so the consumer
	 * side only sees the tickets filed in its favour.
	 *
	 * The rows are separate documents (not domain content), created,
	 * patched, and deleted through the document API. Acceptance is not a
	 * document action — the dedicated routes bypass the `read_only` flag —
	 * but `POST .../activate` shares the action URL, so `ref.action()`
	 * reaches them. Affordances follow the session's permission manifest:
	 * without `core.DomainGrant` rights the pane renders read-only.
	 */
	import Badge from '$lib/components/primitives/data/Badge.svelte';
	import AlertBanner from '$lib/components/primitives/content/AlertBanner.svelte';
	import Button from '$lib/components/primitives/actions/Button.svelte';
	import Input from '$lib/components/primitives/forms/Input.svelte';
	import Select from '$lib/components/primitives/forms/Select.svelte';
	import type { SelectOption } from '$lib/components/primitives/forms/Select.svelte';
	import ReferencePicker from '$lib/components/primitives/forms/ReferencePicker.svelte';
	import { can } from '$lib/permissions.svelte';
	import { createMutator } from '$lib/utils/mutator.svelte.js';
	import type { DoctypeDefinitionRegistry } from '$lib/datasource/DoctypeRegistry.js';
	import type { ListItem } from '$lib/datasource/types.js';
	import { isSystemDomain } from '$lib/systemDomains.js';
	import { X, Plus, Trash2 } from '@lucide/svelte';
	import * as m from '$lib/paraglide/messages';
	import {
		DEFAULT_TAG,
		composeResourceRows,
		grantDomainId,
		resourceRowsError,
		resourceRowsFrom,
		type DomainGrantContent,
		type ResourceRow
	} from './domainGrants.js';

	let {
		registry,
		domain,
		issued,
		held,
		doctypeNames,
		loading = false,
		error,
		onreload
	}: {
		/** Driver-backed registry — the grant documents read and written through it. */
		registry: DoctypeDefinitionRegistry;
		/** Domain id — the producer of the issued grants, the consumer of the held ones. */
		domain: string;
		/** Grants filed under this domain (children), loaded by the parent. */
		issued: ListItem<DomainGrantContent>[];
		/** Grants under other domains naming this domain as consumer, loaded by the parent. */
		held: ListItem<DomainGrantContent>[];
		/** This domain's doctype names — the resource doctype options. */
		doctypeNames: string[];
		/** True while the parent reloads the lists. */
		loading?: boolean;
		/** Parent-side load error. */
		error?: string;
		/** Called after each successful mutation so the parent re-reads. */
		onreload: () => void | Promise<void>;
	} = $props();

	// One DataSource per collection, derived so a registry swap re-binds.
	const grantsDs = $derived(registry.domain('core').doctype<DomainGrantContent>('DomainGrant'));
	const domainDs = $derived(registry.domain('core').doctype('Domain'));

	const mutator = createMutator();

	// Acceptance is the producer's right (D5), held doctype-global. The
	// system domains hold no grants — the producer picker excludes nothing,
	// but the backend validator rejects a self-grant with a 422.
	const canCreate = $derived(can('core.DomainGrant', 'create') && !isSystemDomain(domain));
	const canDelete = $derived(can('core.DomainGrant', 'delete'));
	const canActivate = $derived(can('core.DomainGrant', 'activate'));
	const canDeactivate = $derived(can('core.DomainGrant', 'deactivate'));
	const canEdit = $derived(can('core.DomainGrant', 'update'));

	// ── Create ─────────────────────────────────────────────────────────────

	// The new-grant card: a consumer reference plus an empty resources
	// bundle (the typed schema accepts an empty array; the producer adds
	// entries before activating).
	let creating = $state(false);
	let newConsumer = $state('');

	function openCreate() {
		creating = true;
		newConsumer = '';
	}

	async function submitCreate() {
		await mutator.run('create', async () => {
			await domainDs.doc(domain).children<DomainGrantContent>('grants').create({
				consumer_domain: newConsumer,
				resources: []
			});
			creating = false;
			newConsumer = '';
			await onreload();
		});
	}

	// ── Issued grants: per-card editing ───────────────────────────────

	// Each card owns a working copy of its resources (rows keyed by the
	// grant id, seeded lazily from the loaded document). The working copy
	// becomes the source of truth once seeded — the same clone-and-edit
	// model the old grants-array editor used. `activate`/`deactivate` ride
	// the dedicated routes through `action()`; the `read_only` flag keeps
	// every other write off the field.

	const workingRows = $state<Record<string, ResourceRow[]>>({});

	function rowsFor(grant: ListItem<DomainGrantContent>): ResourceRow[] {
		return workingRows[grant.meta.id] ?? resourceRowsFrom(grant.data.resources);
	}

	function setRows(grant: ListItem<DomainGrantContent>, rows: ResourceRow[]) {
		workingRows[grant.meta.id] = rows;
	}

	function addRow(grant: ListItem<DomainGrantContent>) {
		setRows(grant, [...rowsFor(grant), { doctype: '', tags: '' }]);
	}

	function removeRow(grant: ListItem<DomainGrantContent>, index: number) {
		setRows(
			grant,
			rowsFor(grant).filter((_, i) => i !== index)
		);
	}

	// Doctype options for one card — the domain's doctypes; the selected
	// value stays visible even when the doctype set moved on.
	function doctypeOptions(grant: ListItem<DomainGrantContent>): SelectOption[] {
		const names = new Set(doctypeNames);
		const current = rowsFor(grant)
			.map((r) => r.doctype.trim())
			.filter((d) => d && !names.has(d));
		const all = [...new Set([...doctypeNames, ...current])];
		return all.map((n) => ({ value: n, label: n }));
	}

	async function saveGrant(grant: ListItem<DomainGrantContent>) {
		const rows = rowsFor(grant);
		const invalid = resourceRowsError(rows);
		if (invalid) {
			// The banner channel is the card's error surface — the save never
			// fires with a shape the backend validator would reject.
			mutator.clearError();
			setCardError(grant.meta.id, invalid);
			return;
		}
		clearCardError(grant.meta.id);
		await mutator.run(`save::${grant.meta.id}`, async () => {
			await grantsDs.doc(grant.meta.id).update({ resources: composeResourceRows(rows) });
			await onreload();
		});
	}

	async function toggleActive(grant: ListItem<DomainGrantContent>, active: boolean) {
		await mutator.run(`active::${grant.meta.id}`, async () => {
			await grantsDs.doc(grant.meta.id).action(active ? 'activate' : 'deactivate');
			await onreload();
		});
	}

	async function removeGrant(grant: ListItem<DomainGrantContent>) {
		await mutator.run(`rm::${grant.meta.id}`, async () => {
			await grantsDs.doc(grant.meta.id).delete();
			await onreload();
		});
	}

	// Per-card inline validation error (separate from the mutator's
	// action-error banner — a validation message belongs to one card).
	let cardErrors = $state<Record<string, string>>({});

	function setCardError(id: string, message: string) {
		cardErrors = { ...cardErrors, [id]: message };
	}

	function clearCardError(id: string) {
		const { [id]: _dropped, ...rest } = cardErrors;
		cardErrors = rest;
	}

	function grantBusy(grant: ListItem<DomainGrantContent>): boolean {
		return (
			mutator.busyId === `save::${grant.meta.id}` ||
			mutator.busyId === `active::${grant.meta.id}` ||
			mutator.busyId === `rm::${grant.meta.id}`
		);
	}
</script>

<div class="fsec">
	<!-- ── Issued grants ─────────────────────────────────────────────────── -->
	<div class="sec-head">
		<h2 class="sec-title">{m.configure_grants_issued_title()}</h2>
		{#if canCreate && !creating}
			<Button variant="ghost" size="sm" onclick={openCreate}>
				{#snippet iconLeft()}
					<Plus size={14} strokeWidth={2} aria-hidden="true" />
				{/snippet}
				{m.configure_grants_add_button()}
			</Button>
		{/if}
	</div>
	<p class="sec-hint">{m.configure_grants_issued_helper()}</p>

	{#if error}
		<AlertBanner message={error} />
	{/if}
	{#if mutator.error}
		<AlertBanner message={mutator.error} dismissable onDismiss={() => mutator.clearError()} />
	{/if}

	{#if creating}
		<div class="card new-card">
			<div class="card-head">
				<span class="card-title">{m.configure_grants_new_title()}</span>
				<button
					class="icon-btn"
					type="button"
					aria-label={m.common_cancel()}
					onclick={() => (creating = false)}
				>
					<X size={14} strokeWidth={1.8} />
				</button>
			</div>
			<div class="new-row">
				<ReferencePicker
					label={m.configure_grants_consumer_label()}
					doctype="core.Domain"
					driver={registry}
					required
					bind:value={newConsumer}
				/>
				<Button
					variant="primary"
					size="md"
					loading={mutator.busyId === 'create'}
					disabled={!newConsumer || mutator.busy}
					onclick={submitCreate}
				>
					{m.common_create()}
				</Button>
			</div>
			<p class="hint">{m.configure_grants_new_helper()}</p>
		</div>
	{/if}

	{#if loading}
		<p class="status">{m.configure_grants_loading()}</p>
	{:else if issued.length === 0}
		<div class="empty-card">{m.configure_grants_issued_empty()}</div>
	{:else}
		{#each issued as grant (grant.meta.id)}
			{@const consumer = grantDomainId(grant.data.consumer_domain)}
			{@const active = grant.data.active === true}
			<div class="card">
				<div class="card-head">
					<span class="card-title mono">
						{m.configure_grants_for({ consumer })}
					</span>
					<span class="sp"></span>
					<Badge
						variant={active ? 'ok' : 'warn'}
						size="sm"
						label={active ? m.configure_grants_state_active() : m.configure_grants_state_inactive()}
					/>
					{#if canDeactivate && active}
						<Button
							variant="ghost"
							size="sm"
							loading={mutator.busyId === `active::${grant.meta.id}`}
							disabled={mutator.busy}
							onclick={() => toggleActive(grant, false)}
						>
							{m.configure_grants_deactivate()}
						</Button>
					{:else if canActivate && !active}
						<Button
							variant="primary"
							size="sm"
							loading={mutator.busyId === `active::${grant.meta.id}`}
							disabled={mutator.busy}
							onclick={() => toggleActive(grant, true)}
						>
							{m.configure_grants_activate()}
						</Button>
					{/if}
					{#if canDelete}
						<button
							class="icon-btn danger"
							type="button"
							aria-label={m.configure_grants_remove_aria()}
							disabled={mutator.busy}
							onclick={() => removeGrant(grant)}
						>
							<Trash2 size={14} strokeWidth={1.8} />
						</button>
					{/if}
				</div>

				<div class="resources">
					<div class="res-head">
						<span class="res-label">{m.configure_grants_resources_label()}</span>
					</div>
					{#each rowsFor(grant) as row, i (`${grant.meta.id}-${i}`)}
						<div class="res-row">
							<Select
								label={i === 0 ? m.configure_grants_doctype_label() : undefined}
								options={doctypeOptions(grant)}
								value={row.doctype}
								disabled={!canEdit}
								onValueChange={(v) => {
									setRows(
										grant,
										rowsFor(grant).map((r, ri) => (ri === i ? { ...r, doctype: v } : r))
									);
								}}
							/>
							<Input
								label={i === 0 ? m.configure_grants_tags_label() : undefined}
								value={row.tags}
								placeholder={m.configure_grants_tags_placeholder()}
								disabled={!canEdit}
								oninput={(e) => {
									const target = e.target as HTMLInputElement;
									setRows(
										grant,
										rowsFor(grant).map((r, ri) => (ri === i ? { ...r, tags: target.value } : r))
									);
								}}
							/>
							{#if canEdit && rowsFor(grant).length > 1}
								<button
									class="icon-btn danger res-rm"
									type="button"
									aria-label={m.configure_grants_remove_row_aria({
										doctype: row.doctype || m.configure_grants_row_new()
									})}
									onclick={() => removeRow(grant, i)}
								>
									<X size={13} strokeWidth={1.8} />
								</button>
							{/if}
						</div>
					{:else}
						<p class="hint">{m.configure_grants_resources_empty()}</p>
					{/each}
					{#if canEdit}
						<button class="add-row-btn" type="button" onclick={() => addRow(grant)}>
							<Plus size={13} strokeWidth={2} aria-hidden="true" />
							{m.configure_grants_add_row_button()}
						</button>
					{/if}
					{#if cardErrors[grant.meta.id]}
						<p class="input-err" role="alert">{cardErrors[grant.meta.id]}</p>
					{/if}
					{#if canEdit}
						<div class="card-actions">
							<Button
								variant="secondary"
								size="sm"
								loading={mutator.busyId === `save::${grant.meta.id}`}
								disabled={grantBusy(grant) || mutator.busy}
								onclick={() => saveGrant(grant)}
							>
								{m.common_save()}
							</Button>
						</div>
					{/if}
					<p class="hint">{m.configure_grants_resources_helper()}</p>
				</div>
			</div>
		{/each}
	{/if}
</div>

<div class="fsec">
	<!-- ── Held access ───────────────────────────────────────────────────── -->
	<div class="sec-head">
		<h2 class="sec-title">{m.configure_grants_held_title()}</h2>
	</div>
	<p class="sec-hint">{m.configure_grants_held_helper()}</p>

	{#if loading}
		<p class="status">{m.configure_grants_loading()}</p>
	{:else if held.length === 0}
		<div class="empty-card">{m.configure_grants_held_empty()}</div>
	{:else}
		{#each held as grant (grant.meta.id)}
			{@const producer = grant.meta.parent_id ?? ''}
			{@const active = grant.data.active === true}
			<div class="card held">
				<div class="card-head">
					<span class="card-title mono">
						{m.configure_grants_from({ producer })}
					</span>
					<span class="sp"></span>
					<Badge
						variant={active ? 'ok' : 'warn'}
						size="sm"
						label={active ? m.configure_grants_state_active() : m.configure_grants_state_inactive()}
					/>
				</div>
				<div class="held-resources">
					{#each grant.data.resources ?? [] as res, i (`${grant.meta.id}-${i}`)}
						<span class="held-res">
							<span class="mono">{res.doctype}</span>
							<span class="held-tags">
								{#each res.tags as tag, j (`${grant.meta.id}-${i}-${j}`)}
									<span class="held-tag" class:default-tag={tag === DEFAULT_TAG}>{tag}</span>
								{:else}
									<span class="held-tag">{m.configure_grants_no_tags()}</span>
								{/each}
							</span>
						</span>
					{:else}
						<span class="hint">{m.configure_grants_resources_empty()}</span>
					{/each}
				</div>
			</div>
		{/each}
	{/if}
</div>

<style>
	.fsec {
		margin-bottom: 26px;
	}
	.sec-head {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 12px;
		padding-bottom: 7px;
		border-bottom: 1px solid var(--border);
	}
	.sec-head .sec-title {
		font-size: 11px;
		font-weight: 600;
		letter-spacing: 0.06em;
		text-transform: uppercase;
		color: var(--text-3);
		margin: 0;
	}
	.sec-hint {
		font-size: 12px;
		color: var(--text-3);
		line-height: 1.5;
		margin: 8px 0 14px;
	}
	.empty-card {
		border: 1px dashed var(--border);
		border-radius: var(--r);
		padding: 18px;
		font-size: 12.5px;
		color: var(--text-3);
		text-align: center;
	}
	.status {
		font-size: 13px;
		color: var(--text-3);
	}

	.card {
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface);
		padding: 13px 16px;
		margin-bottom: 12px;
	}
	.card-head {
		display: flex;
		align-items: center;
		gap: 10px;
		margin-bottom: 10px;
	}
	.card-head .sp {
		flex: 1;
	}
	.card-title {
		font-size: 13px;
		font-weight: 600;
	}
	.mono {
		font-family: var(--font-mono);
	}

	.icon-btn {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: 26px;
		height: 26px;
		border: 1px solid transparent;
		border-radius: var(--r-sm);
		background: none;
		cursor: pointer;
		color: var(--text-3);
		transition:
			background 0.1s,
			color 0.1s;
	}
	.icon-btn:hover {
		background: var(--sunken);
		color: var(--text);
	}
	.icon-btn.danger:hover {
		color: var(--danger);
		background: var(--danger-weak);
	}
	.icon-btn:disabled {
		cursor: not-allowed;
		opacity: 0.45;
	}

	.new-row {
		display: flex;
		align-items: end;
		gap: 10px;
	}
	.new-row > :global(.rp-wrap) {
		flex: 1;
	}
	.new-card .hint {
		margin-top: 8px;
	}

	.resources {
		display: flex;
		flex-direction: column;
		gap: 8px;
	}
	.res-head {
		display: flex;
		align-items: center;
		justify-content: space-between;
	}
	.res-label {
		font-size: 12.5px;
		font-weight: 600;
		color: var(--text-2);
	}
	.res-row {
		display: grid;
		grid-template-columns: 1fr 1.4fr auto;
		gap: 8px;
		align-items: end;
	}
	.res-rm {
		margin-bottom: 2px;
	}
	.add-row-btn {
		display: inline-flex;
		align-items: center;
		gap: 5px;
		align-self: start;
		border: none;
		background: none;
		padding: 2px 0;
		font-size: 12px;
		font-weight: 600;
		color: var(--text-2);
		cursor: pointer;
	}
	.add-row-btn:hover {
		color: var(--text);
	}
	.card-actions {
		display: flex;
		justify-content: flex-end;
		margin-top: 2px;
	}
	.input-err {
		font-size: 11.5px;
		color: var(--danger);
		margin: 0;
	}
	.hint {
		font-size: 11.5px;
		color: var(--text-3);
		margin: 0;
		line-height: 1.4;
	}

	.held .held-resources {
		display: flex;
		flex-direction: column;
		gap: 5px;
	}
	.held-res {
		display: flex;
		align-items: baseline;
		gap: 10px;
		font-size: 12.5px;
	}
	.held-tags {
		display: inline-flex;
		flex-wrap: wrap;
		gap: 4px;
	}
	.held-tag {
		font-family: var(--font-mono);
		font-size: 11px;
		padding: 1px 8px;
		border-radius: 999px;
		background: var(--surface-2);
		border: 1px solid var(--border-2);
		color: var(--text-2);
	}
	.default-tag {
		color: var(--text-3);
		font-style: italic;
	}

	@media (max-width: 720px) {
		.res-row {
			grid-template-columns: 1fr;
		}
	}
</style>
