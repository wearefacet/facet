<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { page } from '$app/state';
	import { invalidateAll } from '$app/navigation';

	import PageHeader from '$lib/components/primitives/surfaces/PageHeader.svelte';
	import AlertBanner from '$lib/components/primitives/content/AlertBanner.svelte';
	import Button from '$lib/components/primitives/actions/Button.svelte';
	import RowList from '$lib/components/primitives/data/RowList.svelte';
	import RowItem from '$lib/components/primitives/data/RowItem.svelte';
	import Select from '$lib/components/primitives/forms/Select.svelte';
	import type { SelectOption } from '$lib/components/primitives/forms/Select.svelte';
	import RoleMemberRow from '$lib/components/features/admin/RoleMemberRow.svelte';
	import { UserPlus, ArrowLeft } from '@lucide/svelte';
	import { DocumentDataDriver } from '$lib/datasource/DocumentDriver.js';
	import { createMutator } from '$lib/utils/mutator.svelte.js';
	import { applyRoleChange } from '$lib/authorization/accountRoles.js';
	import { roleDocIdToName, humanizeRoleName, hasRole } from '$lib/authorization/roleMembership.js';
	import { onPermissionRefresh } from '$lib/authorization/permissionRefresh.svelte.js';
	import { errorMessage } from '$lib/datasource/bannerError.js';
	import type { AccountContent } from '$lib/iam/content.js';
	import * as m from '$lib/paraglide/messages';

	/**
	 * Role assignment page — lists the accounts currently assigned to one
	 * role and lets the operator add or remove accounts. The role id in the
	 * URL is the role document id (`iam.Roles.{name}`), matching the form
	 * stored on `iam.Account.roles`.
	 *
	 * There is no array-contains filter on the document list API, so the
	 * page loads every `iam.Account` once and filters client-side. Facet
	 * targets mid-sized organizations, so the full-account scan is
	 * acceptable here (mirrors the Lua delete-guard in
	 * `data/seeds/iam.Roles/script.lua` and the member-count pass in
	 * `roles/+page.svelte`).
	 *
	 * Add / remove PATCHes the account's `roles` array (and `default_role`
	 * when the change makes the persisted default stale). The role document
	 * itself is never mutated.
	 */

	type AccountListItem = { data: AccountContent; meta: { id: string } };

	const roleId = $derived(page.params.id ?? '');
	const roleName = $derived(humanizeRoleName(roleDocIdToName(roleId)));

	let accounts = $state<AccountListItem[]>([]);
	let loadError = $state<string | undefined>(undefined);
	let loaded = $state(false);

	// One busy/error channel for the add / remove actions.
	const mutator = createMutator();

	// Add-account picker value (Bits UI Combobox binds a single string).
	let addValue = $state('');

	// Single shared driver for all reads and writes on this page.
	const driver = new DocumentDataDriver('');

	async function loadAll() {
		try {
			const res = await driver.domain('iam').doctype('Account').list({ items: 10000 });
			accounts = res.data as AccountListItem[];
			loadError = undefined;
		} catch (err) {
			loadError = errorMessage(err);
		} finally {
			loaded = true;
		}
	}

	$effect(() => {
		void page.url.pathname;
		void roleId;
		loadAll();
	});

	// Reload every account row on permission refresh.
	onPermissionRefresh(() => {
		void loadAll();
		void invalidateAll();
	});

	// Members of this role: accounts whose `roles` array contains the role id.
	const members = $derived(
		accounts
			.filter((acc) => hasRole(acc.data.roles, roleId))
			.sort((a, b) => {
				const na = a.data.name ?? a.data.email ?? a.meta.id;
				const nb = b.data.name ?? b.data.email ?? b.meta.id;
				return na.localeCompare(nb);
			})
	);

	// Candidates for the add-account picker: accounts NOT yet assigned.
	const addCandidates = $derived(
		accounts
			.filter((acc) => !hasRole(acc.data.roles, roleId))
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
		const account = accounts.find((a) => a.meta.id === selectedCandidate.value);
		if (!account) return;
		await mutator.run(`add::${account.meta.id}`, async () => {
			await applyRoleChange(driver, account.meta.id, account.data, 'assign', roleId);
			addValue = '';
			await loadAll();
			await invalidateAll();
		});
	}

	async function removeMember(accountId: string) {
		const account = accounts.find((a) => a.meta.id === accountId);
		if (!account) return;
		await mutator.run(`rm::${accountId}`, async () => {
			await applyRoleChange(driver, accountId, account.data, 'unassign', roleId);
			await loadAll();
			await invalidateAll();
		});
	}

	function isDefault(account: AccountListItem): boolean {
		const d = account.data.default_role;
		return typeof d === 'string' && d.length > 0 && d === roleId;
	}
</script>

<svelte:head>
	<title>{m.configure_role_members_page_title({ name: roleName })}</title>
</svelte:head>

<div class="page">
	<PageHeader title={m.configure_role_members_tab()} subtitle={m.configure_role_members_subtitle()}>
		{#snippet actions()}
			<Button variant="ghost" size="sm" href="/Configure/access/roles">
				{#snippet iconLeft()}
					<ArrowLeft size={13} strokeWidth={2} aria-hidden="true" />
				{/snippet}
				{m.configure_role_back_button()}
			</Button>
		{/snippet}
	</PageHeader>

	<div class="role-chip">
		<span class="chip-label">{m.common_role()}</span>
		<span class="chip-name">{roleName}</span>
		<span class="chip-id">{roleId}</span>
	</div>

	{#if loadError}
		<AlertBanner message={loadError} dismissable onDismiss={() => (loadError = undefined)} />
	{/if}
	{#if mutator.error}
		<AlertBanner message={mutator.error} dismissable onDismiss={() => mutator.clearError()} />
	{/if}

	<section class="add-section">
		<div class="add-row">
			<div class="add-picker">
				<Select
					bind:value={addValue}
					options={addOptions}
					placeholder={m.configure_assignments_add_account_placeholder()}
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
				{m.configure_assignments_add_to_role()}
			</Button>
		</div>
		{#if addCandidates.length === 0 && loaded}
			<p class="muted-line">{m.configure_role_members_all_assigned()}</p>
		{/if}
	</section>

	{#if !loaded}
		<p class="status">{m.configure_role_accounts_loading()}</p>
	{:else if members.length === 0}
		<RowList>
			<RowItem empty>
				<span class="empty-line">{m.configure_assignments_members_empty()}</span>
			</RowItem>
		</RowList>
	{:else}
		<RowList>
			{#each members as acc (acc.meta.id)}
				<RoleMemberRow
					title={acc.data.name ?? acc.meta.id}
					email={acc.data.email}
					metaId={acc.meta.id}
					status={acc.data.status}
					isDefault={isDefault(acc)}
					removing={mutator.busyId === acc.meta.id}
					disabled={mutator.busy}
					removeTitle={m.configure_role_members_remove_aria()}
					onremove={() => removeMember(acc.meta.id)}
				/>
			{/each}
		</RowList>
	{/if}
</div>

<style>
	.page {
		padding: 28px 32px 48px;
		max-width: 960px;
		margin: 0 auto;
	}

	.role-chip {
		display: inline-flex;
		align-items: center;
		gap: 8px;
		padding: 4px 10px 4px 8px;
		border: 1px solid var(--border);
		border-radius: var(--r-pill, 999px);
		background: var(--surface);
		margin-bottom: 18px;
		font-family: var(--font-mono);
		font-size: 12px;
	}

	.chip-label {
		color: var(--text-3);
	}

	.chip-name {
		color: var(--text);
		font-weight: 600;
	}

	.chip-id {
		color: var(--text-3);
		font-size: 11px;
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

	.status {
		font-size: 13px;
		color: var(--text-3);
	}

	.empty-line {
		color: var(--text-3);
	}
</style>
