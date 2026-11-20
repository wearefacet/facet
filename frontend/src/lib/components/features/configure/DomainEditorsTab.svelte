<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import RowList from '$lib/components/primitives/data/RowList.svelte';
	import RoleMemberRow from '$lib/components/features/admin/RoleMemberRow.svelte';
	import AlertBanner from '$lib/components/primitives/content/AlertBanner.svelte';
	import Button from '$lib/components/primitives/actions/Button.svelte';
	import Select from '$lib/components/primitives/forms/Select.svelte';
	import type { SelectOption } from '$lib/components/primitives/forms/Select.svelte';
	import { UserPlus } from '@lucide/svelte';
	import { can } from '$lib/permissions.svelte';
	import { isSystemDomain } from '$lib/systemDomains.js';
	import { splitQualifiedRef } from '$lib/datasource/qualifiedRef.js';
	import { createMutator } from '$lib/utils/mutator.svelte.js';
	import { errorMessage } from '$lib/datasource/bannerError.js';
	import type { DoctypeDefinitionRegistry } from '$lib/datasource/DoctypeRegistry.js';
	import type { ListItem } from '$lib/datasource/types.js';
	import type { AccountContent } from '$lib/iam/content.js';
	import type { DomainEditorContent } from './domainSecurity.js';
	import * as m from '$lib/paraglide/messages';

	/**
	 * Editors pane of the domain editor — the `core.DomainEditor` grant list
	 * for one domain: the accounts that may edit its definition (its domain
	 * document, doctypes, and document views).
	 *
	 * The rows are separate admin-managed documents, created and soft-deleted
	 * through the generic document API; the parent owns the list read (and the
	 * tab-count badge) and re-reads it through `onreload` after each mutation.
	 * Affordances follow the backend's RBAC shape: the editor role carves
	 * `core.DomainEditor` out of its blanket lines, so only roles holding the
	 * grants (admin by seed) see add/remove; everyone else gets a read-only
	 * list. System domains never carry rows — the doctype's Lua guard rejects
	 * them — so they render a note instead of a dead picker.
	 */

	let {
		registry,
		domain,
		rows,
		loading = false,
		error,
		onreload
	}: {
		/** Driver-backed registry — accounts and grant rows read through it. */
		registry: DoctypeDefinitionRegistry;
		/** Domain id the grants target — live slug or `_`-prefixed draft id. */
		domain: string;
		/** The domain's grant rows, loaded by the parent. */
		rows: ListItem<DomainEditorContent>[];
		/** True while the parent reloads the rows. */
		loading?: boolean;
		/** Parent-side load error over the rows. */
		error?: string;
		/** Called after each successful add/remove so the parent re-reads. */
		onreload: () => void | Promise<void>;
	} = $props();

	type AccountListItem = ListItem<AccountContent>;

	// One DataSource per collection, derived so a registry swap re-binds (the
	// mock and HTTP drivers memoize their domain objects, so this is cheap).
	const editors = $derived(registry.domain('core').doctype<DomainEditorContent>('DomainEditor'));
	const accountsDs = $derived(registry.domain('iam').doctype<AccountContent>('Account'));

	// Busy/error channel for the add / remove actions.
	const mutator = createMutator();

	// Add-picker value (the Select binds a single account id).
	let addValue = $state('');

	// All accounts, loaded once — labels the rows and feeds the picker. Facet
	// targets mid-sized organizations, so the full-account scan is acceptable
	// (mirrors the role members page).
	let accounts = $state<AccountListItem[]>([]);
	let accountsLoading = $state(false);
	let accountsError = $state<string | undefined>(undefined);

	async function loadAccounts() {
		accountsLoading = true;
		accountsError = undefined;
		try {
			const res = await accountsDs.list({ items: 10000 });
			accounts = res.data as AccountListItem[];
		} catch (err) {
			accountsError = errorMessage(err);
		} finally {
			accountsLoading = false;
		}
	}

	$effect(() => {
		loadAccounts();
	});

	// The grant list is admin-only (the editor role's `except` carve-outs),
	// and the backend guard rejects system domains outright.
	const canAdd = $derived(can('core.DomainEditor', 'create') && !isSystemDomain(domain));
	const canRemove = $derived(can('core.DomainEditor', 'delete') && !isSystemDomain(domain));

	// Rows joined with their account documents; the label falls back to the
	// row's display name, then the raw reference, then the row id — a dangling
	// or unresolvable account must still render.
	const memberRows = $derived(
		rows
			.map((row) => {
				const ref = splitQualifiedRef(row.data.account);
				const account = ref ? accounts.find((a) => a.meta.id === ref.id) : undefined;
				const label =
					account?.data.name ??
					account?.data.email ??
					row.meta.display_name ??
					row.data.account ??
					row.meta.id;
				return { row, account, label };
			})
			.sort((a, b) => a.label.localeCompare(b.label))
	);

	// Picker candidates: accounts without a grant row on this domain.
	const addCandidates = $derived(
		accounts
			.filter((acc) => !memberRows.some((mr) => mr.account?.meta.id === acc.meta.id))
			.map((acc) => ({
				value: acc.meta.id,
				label: acc.data.name ?? acc.data.email ?? acc.meta.id,
				email: acc.data.email
			}))
			.sort((a, b) => a.label.localeCompare(b.label))
	);

	const addOptions = $derived<SelectOption[]>(
		addCandidates.map((c) => ({ value: c.value, label: c.label }))
	);

	const selectedCandidate = $derived(addCandidates.find((c) => c.value === addValue) ?? null);

	async function addSelected() {
		if (!selectedCandidate) return;
		const account = `iam.Account.${selectedCandidate.value}`;
		await mutator.run(`add::${selectedCandidate.value}`, async () => {
			await editors.create({ account, domain });
			addValue = '';
			await onreload();
		});
	}

	async function removeRow(row: ListItem<DomainEditorContent>) {
		await mutator.run(`rm::${row.meta.id}`, async () => {
			await editors.doc(row.meta.id).delete();
			await onreload();
		});
	}
</script>

<div class="fsec">
	<div class="sec-head">
		<h2 class="sec-title">{m.configure_domains_editors_title()}</h2>
	</div>
	<p class="sec-hint">{m.configure_domains_editors_helper()}</p>

	{#if error}
		<AlertBanner message={error} />
	{/if}
	{#if accountsError}
		<AlertBanner message={accountsError} />
	{/if}
	{#if mutator.error}
		<AlertBanner message={mutator.error} dismissable onDismiss={() => mutator.clearError()} />
	{/if}

	{#if isSystemDomain(domain)}
		<div class="empty-card">{m.configure_domains_editors_system_note()}</div>
	{:else}
		{#if canAdd}
			<section class="add-section">
				<div class="add-row">
					<div class="add-picker">
						<Select
							bind:value={addValue}
							options={addOptions}
							placeholder={m.configure_domains_editors_add_placeholder()}
							loading={accountsLoading}
							searchable
						>
							{#snippet renderItem({ value, label })}
								{@const candidate = addCandidates.find((c) => c.value === value)}
								<div class="option">
									<span class="option-label">{label}</span>
									{#if candidate?.email}
										<span class="option-email">{candidate.email}</span>
									{/if}
								</div>
							{/snippet}
						</Select>
					</div>
					<Button
						variant="primary"
						size="md"
						disabled={!selectedCandidate || mutator.busy}
						onclick={addSelected}
					>
						{#snippet iconLeft()}
							<UserPlus size={14} strokeWidth={2} aria-hidden="true" />
						{/snippet}
						{m.configure_domains_editors_add_button()}
					</Button>
				</div>
				{#if addCandidates.length === 0 && !accountsLoading}
					<p class="muted-line">{m.configure_domains_editors_all_listed()}</p>
				{/if}
			</section>
		{/if}

		{#if loading}
			<p class="status">{m.configure_domains_editors_loading()}</p>
		{:else if memberRows.length === 0}
			<div class="empty-card">{m.configure_domains_editors_empty()}</div>
		{:else}
			<RowList>
				{#each memberRows as mrow (mrow.row.meta.id)}
					<RoleMemberRow
						title={mrow.label}
						email={mrow.account?.data.email}
						metaId={mrow.account?.meta.id}
						status={mrow.account?.data.status}
						removable={canRemove}
						removing={mutator.busyId === mrow.row.meta.id}
						disabled={mutator.busy}
						removeTitle={m.configure_domains_editors_remove_aria()}
						onremove={() => removeRow(mrow.row)}
					/>
				{/each}
			</RowList>
		{/if}
	{/if}
</div>

<style>
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
		margin: 8px 0 16px;
	}
	.empty-card {
		border: 1px dashed var(--border);
		border-radius: var(--r);
		padding: 18px;
		font-size: 12.5px;
		color: var(--text-3);
		text-align: center;
	}

	.add-section {
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface);
		padding: 14px;
		margin-bottom: 20px;
	}
	.add-row {
		display: flex;
		align-items: center;
		gap: 10px;
	}
	.add-picker {
		flex: 1 1 auto;
		min-width: 0;
	}
	.muted-line {
		margin: 10px 2px 0;
		font-size: 12px;
		color: var(--text-3);
	}

	.status {
		font-size: 13px;
		color: var(--text-3);
	}

	.option {
		display: flex;
		flex-direction: column;
		gap: 1px;
		min-width: 0;
	}
	.option-label {
		font-size: 13px;
		color: var(--text);
	}
	.option-email {
		font-family: var(--font-mono);
		font-size: 11px;
		color: var(--text-3);
	}
</style>
