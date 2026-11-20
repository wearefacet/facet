<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { page } from '$app/state';
	import { untrack } from 'svelte';

	import AlertBanner from '../../primitives/content/AlertBanner.svelte';
	import Button from '../../primitives/actions/Button.svelte';
	import RowList from '../../primitives/data/RowList.svelte';
	import RowItem from '../../primitives/data/RowItem.svelte';
	import Select from '../../primitives/forms/Select.svelte';
	import RoleMemberRow from './RoleMemberRow.svelte';
	import { UserPlus, KeyRound, UserCog } from '@lucide/svelte';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { DocumentMeta, ListItem } from '$lib/datasource/types.js';
	import { createMutator } from '$lib/utils/mutator.svelte.js';
	import { errorMessage } from '$lib/datasource/bannerError.js';
	import * as m from '$lib/paraglide/messages';
	import {
		roleDocIdToName,
		humanizeRoleName,
		hasRole,
		dedupeRoleIds
	} from '$lib/authorization/roleMembership.js';
	import { applyRoleChange } from '$lib/authorization/accountRoles.js';
	import { onPermissionRefresh } from '$lib/authorization/permissionRefresh.svelte.js';
	import type { AccountContent, RoleContent } from '$lib/iam/content.js';
	import { SvelteMap } from 'svelte/reactivity';

	/**
	 * RoleAssignmentEditor — the two-mode membership editor behind
	 * `/Configure/access/assignments`.
	 *
	 * Mode `role`: pick a role, see its members, add or remove accounts.
	 * Mode `account`: pick an account, see its roles, add or remove roles.
	 *
	 * The host page owns the URL state (`?mode=`, `?role=`, `?account=`) and
	 * the page chrome. This component owns the loaders, the search debounce,
	 * and the membership mutations. The driver is injected, so stories can
	 * mount a mock driver (same pattern as `RbacEditor`). The host passes
	 * `onnavigate` to update the URL state and `onrefresh` to re-run its load
	 * functions (SvelteKit `invalidateAll` in the app).
	 *
	 * The role-id form on `iam.Account.roles` is `iam.Roles.{name}`
	 * (e.g. `iam.Roles.admin`). The document id of every `iam.Account` is a
	 * bare ULID-like id; for display we fall back to `name` →
	 * `email` → `meta.id`.
	 *
	 * ── Scaling ────────────────────────────────────────────────────────────
	 * The list API has no array-contains filter, so "list the accounts that
	 * have role X" cannot be answered with a single filtered query. The two
	 * modes resolve this asymmetrically:
	 *
	 * - Mode `account` is the scalable direction — the component fetches ONE
	 *   account document (`GET /Api/iam/Account/:id`) and reads its `roles`
	 *   array. The cost is bounded by the size of that array, not by the
	 *   size of the account table.
	 * - Mode `role` mirrors the backend Lua delete-guard
	 *   (`data/seeds/iam.Roles/script.lua`): it lists accounts once, then
	 *   filters client-side on `roles` membership. Facet targets mid-sized
	 *   organizations where this scan is acceptable; if a single role's
	 *   membership grows large, a dedicated backend endpoint is the right
	 *   next step.
	 *
	 * Subject pickers (role / account) use `Select` in async mode: the search
	 * queries the server (`email__match` on accounts, `name__match` on
	 * roles), so a large user or role table does not load all rows at once.
	 */

	type Mode = 'role' | 'account';

	let {
		/** Driver for `iam` documents. Injectable so stories can mount a mock
		 * driver. */
		driver,
		/** Active view mode — driven by the host's `?mode=` URL param. */
		mode = 'role',
		/** Selected role document id — the host's `?role=` URL param. */
		selectedRole = '',
		/** Selected account document id — the host's `?account=` URL param. */
		selectedAccount = '',
		/** Ask the host to update the URL state (mode toggle and subject pickers). */
		onnavigate,
		/** Host hook after each successful membership change and on the
		 * permission-refresh signal — re-runs the host load functions. */
		onrefresh
	}: {
		driver: DataDriver;
		mode?: Mode;
		selectedRole?: string;
		selectedAccount?: string;
		onnavigate?: (next: { mode?: Mode; role?: string; account?: string }) => void;
		onrefresh?: () => void | Promise<void>;
	} = $props();

	// ── Loaders ──────────────────────────────────────────────────────────
	let loadError = $state<string | undefined>(undefined);

	// One busy/error channel for every membership action; `busyId` keys the
	// row or picker that owns the in-flight action.
	const mutator = createMutator();

	// ── Mode `role`: members of the selected role ───────────────────────
	let roleMembers = $state<ListItem<AccountContent>[]>([]);
	let roleMembersLoaded = $state(false);

	// Search-as-you-type results for the account picker, populated by the
	// list API (`email__match`). Kept small (capped at one page).
	type FlatOption = { value: string; label: string };
	let accountSearchResults = $state<FlatOption[]>([]);

	// ── Mode `account`: roles of the selected account ──────────────────
	let accountDoc = $state<{ data: AccountContent; meta: DocumentMeta } | null>(null);
	let accountRolesLoaded = $state(false);

	// Resolved role documents for the account's assigned role ids. Keyed by
	// role document id. Loaded once after the account document lands; the
	// size is bounded by the account's role count (small).
	let resolvedRoles = $state<Map<string, { data: RoleContent; meta: DocumentMeta }>>(new Map());

	// Search-as-you-type results for the role picker, populated by the list
	// API (`name__match`).
	let roleSearchResults = $state<FlatOption[]>([]);

	// Re-load on route entry / URL param changes.
	$effect(() => {
		void page.url.pathname;
		void mode;
		if (mode === 'role') {
			void selectedRole;
			void loadRoleMembers();
		} else {
			void selectedAccount;
			void loadAccountRoles();
		}
	});

	// Reload this component's loaders on the permission-refresh signal. The
	// host page re-runs its own load functions on the same signal.
	onPermissionRefresh(() => {
		if (mode === 'role') void loadRoleMembers();
		else void loadAccountRoles();
	});

	async function loadRoleMembers() {
		loadError = undefined;
		roleMembersLoaded = false;
		if (!selectedRole) {
			roleMembers = [];
			roleMembersLoaded = true;
			return;
		}
		try {
			const res = await driver.domain('iam').doctype('Account').list({ items: 10000 });
			roleMembers = (res.data as ListItem<AccountContent>[]).filter((acc) =>
				hasRole(acc.data.roles, selectedRole)
			);
		} catch (err) {
			loadError = errorMessage(err);
		} finally {
			roleMembersLoaded = true;
		}
	}

	async function loadAccountRoles() {
		loadError = undefined;
		accountRolesLoaded = false;
		if (!selectedAccount) {
			accountDoc = null;
			resolvedRoles = new Map();
			accountRolesLoaded = true;
			return;
		}
		try {
			const doc = await driver
				.domain('iam')
				.doctype<AccountContent>('Account')
				.doc(selectedAccount)
				.show();
			// Dedupe the persisted `roles` array before rendering — a keyed
			// `{#each}` over it would throw on a duplicate id, and the stale
			// extra entry must be erasable from this very list.
			doc.data.roles = doc.data.roles ? dedupeRoleIds(doc.data.roles) : doc.data.roles;
			accountDoc = doc;
			await resolveRoles(doc.data.roles ?? []);
		} catch (err) {
			loadError = errorMessage(err);
			accountDoc = null;
			resolvedRoles = new Map();
		} finally {
			accountRolesLoaded = true;
		}
	}

	async function resolveRoles(roleDocIds: string[]) {
		// One `iam.Roles` list, then key by id. The role table is small.
		// untrack: these scratch maps are built inside the load effect's call
		// chain — interleaved tracked set/get would re-run the effect and
		// orphan the in-flight work (workflow.md → equality-guard trap).
		const res = await driver.domain('iam').doctype('Roles').list({ items: 500 });
		const byId = untrack(() => new SvelteMap<string, { data: RoleContent; meta: DocumentMeta }>());
		for (const item of res.data as ListItem<RoleContent>[]) {
			untrack(() => byId.set(item.meta.id, { data: item.data, meta: item.meta }));
		}
		// Keep only the assigned ones, plus any unknown ids (display with a
		// weak label so an orphaned id is still visible).
		const out = untrack(() => new SvelteMap<string, { data: RoleContent; meta: DocumentMeta }>());
		for (const id of roleDocIds) {
			const r = untrack(() => byId.get(id));
			if (r) untrack(() => out.set(id, r));
			else untrack(() => out.set(id, { data: {}, meta: { ...emptyMeta, id } }));
		}
		resolvedRoles = out;
	}

	const emptyMeta: DocumentMeta = {
		id: '',
		mid: '',
		domain: 'iam',
		doc_type: 'Roles',
		version: 0,
		schema_version: 1,
		display_name: null,
		created_at: '',
		updated_at: ''
	};

	// ── Pickers (async search) ──────────────────────────────────────────
	let accountSearchTimer: ReturnType<typeof setTimeout> | undefined;
	async function searchAccounts(q: string) {
		// Debounce to avoid one request per keystroke.
		if (accountSearchTimer) clearTimeout(accountSearchTimer);
		accountSearchTimer = setTimeout(async () => {
			try {
				const filters: Record<string, unknown> = q.trim() ? { email__match: q.trim() } : {};
				const res = await driver.domain('iam').doctype('Account').list({ items: 25, filters });
				accountSearchResults = (res.data as ListItem<AccountContent>[]).map((acc) => ({
					value: acc.meta.id,
					label: acc.data.name ?? acc.data.email ?? acc.meta.id
				}));
			} catch {
				accountSearchResults = [];
			}
		}, 200);
	}

	let roleSearchTimer: ReturnType<typeof setTimeout> | undefined;
	async function searchRoles(q: string) {
		if (roleSearchTimer) clearTimeout(roleSearchTimer);
		roleSearchTimer = setTimeout(async () => {
			try {
				const filters: Record<string, unknown> = q.trim() ? { name__match: q.trim() } : {};
				const res = await driver.domain('iam').doctype('Roles').list({ items: 25, filters });
				roleSearchResults = (res.data as ListItem<RoleContent>[]).map((role) => ({
					value: role.meta.id,
					label: role.data.name ? humanizeRoleName(role.data.name) : roleDocIdToName(role.meta.id)
				}));
			} catch {
				roleSearchResults = [];
			}
		}, 200);
	}

	// ── Add-account picker (mode `role`) ────────────────────────────
	let addAccountId = $state('');
	const selectedAddAccount = $derived(
		accountSearchResults.find((r) => r.value === addAccountId) ?? null
	);
	const roleAddCandidates = $derived(
		accountSearchResults.filter((r) => !roleMembers.some((mem) => mem.meta.id === r.value))
	);

	async function addAccountToRole() {
		if (!selectedAddAccount || !selectedRole) return;
		await mutator.run(`addr::${selectedAddAccount.value}`, async () => {
			// Fetch the account document fresh so the PATCH is built from the
			// current `roles` array (the picker may have stale search results).
			const doc = await driver
				.domain('iam')
				.doctype<AccountContent>('Account')
				.doc(selectedAddAccount.value)
				.show();
			await applyRoleChange(driver, doc.meta.id, doc.data, 'assign', selectedRole);
			addAccountId = '';
			await loadRoleMembers();
			await onrefresh?.();
		});
	}

	async function removeAccountFromRole(accountId: string) {
		if (!selectedRole) return;
		const acc = roleMembers.find((mem) => mem.meta.id === accountId);
		if (!acc) return;
		await mutator.run(`rmr::${accountId}`, async () => {
			await applyRoleChange(driver, accountId, acc.data, 'unassign', selectedRole);
			await loadRoleMembers();
			await onrefresh?.();
		});
	}

	// ── Add-role picker (mode `account`) ─────────────────────────────────
	let addRoleId = $state('');
	const selectedAddRole = $derived(roleSearchResults.find((r) => r.value === addRoleId) ?? null);
	const accountAddCandidates = $derived(
		roleSearchResults.filter((r) => !resolvedRoles.has(r.value))
	);

	async function addRoleToAccount() {
		const doc = accountDoc;
		if (!selectedAddRole || !doc) return;
		await mutator.run(`adda::${selectedAddRole.value}`, async () => {
			await applyRoleChange(driver, doc.meta.id, doc.data, 'assign', selectedAddRole.value);
			addRoleId = '';
			await loadAccountRoles();
			await onrefresh?.();
		});
	}

	async function removeRoleFromAccount(roleDocId: string) {
		const doc = accountDoc;
		if (!doc) return;
		await mutator.run(`rma::${roleDocId}`, async () => {
			await applyRoleChange(driver, doc.meta.id, doc.data, 'unassign', roleDocId);
			await loadAccountRoles();
			await onrefresh?.();
		});
	}

	// ── Display helpers ──────────────────────────────────────────────────

	function accountLabel(acc: ListItem<AccountContent>): string {
		return acc.data.name ?? acc.data.email ?? acc.meta.id;
	}

	function roleLabel(roleDocId: string): string {
		const r = resolvedRoles.get(roleDocId);
		if (r?.data.name) return humanizeRoleName(r.data.name);
		return humanizeRoleName(roleDocIdToName(roleDocId));
	}

	function isDefaultRole(roleDocId: string): boolean {
		const d = accountDoc?.data.default_role;
		return typeof d === 'string' && d.length > 0 && d === roleDocId;
	}

	function isDefaultForRole(acc: ListItem<AccountContent>): boolean {
		const d = acc.data.default_role;
		return typeof d === 'string' && d.length > 0 && d === selectedRole;
	}
</script>

{#if loadError}
	<AlertBanner message={loadError} dismissable onDismiss={() => (loadError = undefined)} />
{/if}
{#if mutator.error}
	<AlertBanner message={mutator.error} dismissable onDismiss={() => mutator.clearError()} />
{/if}

<div class="mode-toggle" role="tablist" aria-label={m.configure_assignments_mode_aria()}>
	<button
		type="button"
		role="tab"
		aria-selected={mode === 'role'}
		class:on={mode === 'role'}
		onclick={() => onnavigate?.({ mode: 'role' })}
	>
		<KeyRound size={13} strokeWidth={2} aria-hidden="true" />
		{m.configure_assignments_by_role()}
	</button>
	<button
		type="button"
		role="tab"
		aria-selected={mode === 'account'}
		class:on={mode === 'account'}
		onclick={() => onnavigate?.({ mode: 'account' })}
	>
		<UserCog size={13} strokeWidth={2} aria-hidden="true" />
		{m.configure_assignments_by_account()}
	</button>
</div>

{#if mode === 'role'}
	<section class="panel">
		<div class="panel-head">
			<h2>{m.configure_assignments_members_title()}</h2>
			{#if selectedRole}
				<span class="subject-chip" title={selectedRole}>
					<span class="chip-name">{humanizeRoleName(roleDocIdToName(selectedRole))}</span>
					<span class="chip-id">{selectedRole}</span>
				</span>
			{/if}
		</div>

		<div class="subject-picker">
			<Select
				value={selectedRole}
				placeholder={m.configure_assignments_role_placeholder()}
				searchable
				results={roleSearchResults}
				onsearch={searchRoles}
				onValueChange={(v) => onnavigate?.({ mode: 'role', role: v })}
			>
				{#snippet renderItem({ label })}
					<span class="opt-name">{label}</span>
				{/snippet}
			</Select>
		</div>

		{#if selectedRole}
			<div class="add-section">
				<div class="add-row">
					<div class="add-picker">
						<Select
							bind:value={addAccountId}
							placeholder={m.configure_assignments_add_account_placeholder()}
							searchable
							results={roleAddCandidates}
							onsearch={searchAccounts}
						>
							{#snippet renderItem({ value: _value, label })}
								<div class="opt">
									<span class="opt-label">{label}</span>
								</div>
							{/snippet}
						</Select>
					</div>
					<Button
						variant="primary"
						size="md"
						disabled={!selectedAddAccount || mutator.busy}
						onclick={addAccountToRole}
					>
						{#snippet iconLeft()}
							<UserPlus size={14} strokeWidth={2} aria-hidden="true" />
						{/snippet}
						{m.configure_assignments_add_to_role()}
					</Button>
				</div>
			</div>

			{#if !roleMembersLoaded}
				<p class="status">{m.configure_assignments_members_loading()}</p>
			{:else if roleMembers.length === 0}
				<RowList>
					<RowItem empty>
						<span class="empty-line">{m.configure_assignments_members_empty()}</span>
					</RowItem>
				</RowList>
			{:else}
				<RowList>
					{#each roleMembers as acc (acc.meta.id)}
						<RoleMemberRow
							title={accountLabel(acc)}
							email={acc.data.email}
							metaId={acc.meta.id}
							status={acc.data.status}
							isDefault={isDefaultForRole(acc)}
							removing={mutator.busyId === `rmr::${acc.meta.id}`}
							disabled={mutator.busy}
							onremove={() => removeAccountFromRole(acc.meta.id)}
						/>
					{/each}
				</RowList>
			{/if}
		{:else}
			<p class="status">{m.configure_assignments_pick_role_hint()}</p>
		{/if}
	</section>
{:else}
	<section class="panel">
		<div class="panel-head">
			<h2>{m.configure_assignments_roles_title()}</h2>
			{#if accountDoc}
				<span class="subject-chip" title={accountDoc.meta.id}>
					<span class="chip-name"
						>{accountLabel({ data: accountDoc.data, meta: accountDoc.meta })}</span
					>
					<span class="chip-id">{accountDoc.meta.id}</span>
				</span>
			{/if}
		</div>

		<div class="subject-picker">
			<Select
				value={selectedAccount}
				placeholder={m.configure_assignments_account_placeholder()}
				searchable
				results={accountSearchResults}
				onsearch={searchAccounts}
				onValueChange={(v) => onnavigate?.({ mode: 'account', account: v })}
			>
				{#snippet renderItem({ value: _value, label })}
					<div class="opt">
						<span class="opt-label">{label}</span>
					</div>
				{/snippet}
			</Select>
		</div>

		{#if selectedAccount}
			<div class="add-section">
				<div class="add-row">
					<div class="add-picker">
						<Select
							bind:value={addRoleId}
							placeholder={m.configure_assignments_add_role_placeholder()}
							searchable
							results={accountAddCandidates}
							onsearch={searchRoles}
						>
							{#snippet renderItem({ value: _value, label })}
								<div class="opt">
									<span class="opt-label">{label}</span>
								</div>
							{/snippet}
						</Select>
					</div>
					<Button
						variant="primary"
						size="md"
						disabled={!selectedAddRole || mutator.busy}
						onclick={addRoleToAccount}
					>
						{#snippet iconLeft()}
							<KeyRound size={14} strokeWidth={2} aria-hidden="true" />
						{/snippet}
						{m.configure_assignments_assign_role()}
					</Button>
				</div>
			</div>

			{#if !accountRolesLoaded}
				<p class="status">{m.configure_assignments_roles_loading()}</p>
			{:else if !accountDoc}
				<p class="status">{m.configure_assignments_account_missing()}</p>
			{:else if (accountDoc.data.roles ?? []).length === 0}
				<RowList>
					<RowItem empty>
						<span class="empty-line">{m.configure_assignments_roles_empty()}</span>
					</RowItem>
				</RowList>
			{:else}
				<RowList>
					{#each accountDoc.data.roles ?? [] as roleDocId (roleDocId)}
						{@const r = resolvedRoles.get(roleDocId)}
						<RoleMemberRow
							title={roleLabel(roleDocId)}
							description={r?.data.description}
							metaId={r?.data.description ? undefined : roleDocId}
							isDefault={isDefaultRole(roleDocId)}
							defaultTitle={m.configure_assignments_default_role_aria()}
							removing={mutator.busyId === `rma::${roleDocId}`}
							disabled={mutator.busy}
							onremove={() => removeRoleFromAccount(roleDocId)}
						/>
					{/each}
				</RowList>
			{/if}
		{:else}
			<p class="status">{m.configure_assignments_pick_account_hint()}</p>
		{/if}
	</section>
{/if}

<style>
	.mode-toggle {
		display: inline-flex;
		gap: 2px;
		padding: 3px;
		background: var(--sunken, var(--surface));
		border: 1px solid var(--border);
		border-radius: var(--r);
		margin-bottom: 18px;
	}

	.mode-toggle button {
		display: inline-flex;
		align-items: center;
		gap: 7px;
		padding: 6px 12px;
		border: none;
		border-radius: var(--r-sm, 4px);
		background: transparent;
		color: var(--text-2);
		font: inherit;
		font-size: 12.5px;
		font-weight: 600;
		cursor: pointer;
		transition:
			background 0.12s,
			color 0.12s;
	}

	.mode-toggle button.on {
		background: var(--surface);
		color: var(--text);
		box-shadow: var(--sh-1, 0 1px 2px rgba(0, 0, 0, 0.06));
	}

	.mode-toggle button:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	.panel {
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface);
		padding: 16px 18px 18px;
	}

	.panel-head {
		display: flex;
		align-items: center;
		gap: 10px;
		margin-bottom: 12px;
		flex-wrap: wrap;
	}

	.panel-head h2 {
		margin: 0;
		font-family: var(--font-display);
		font-size: 15px;
		font-weight: 600;
		color: var(--text);
	}

	.subject-chip {
		display: inline-flex;
		align-items: center;
		gap: 8px;
		padding: 3px 10px;
		border: 1px solid var(--border);
		border-radius: var(--r-pill, 999px);
		background: var(--surface);
		font-family: var(--font-mono);
		font-size: 11.5px;
		max-width: 100%;
		overflow: hidden;
	}

	.chip-name {
		color: var(--text);
		font-weight: 600;
	}

	.chip-id {
		color: var(--text-3);
		font-size: 10.5px;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.subject-picker {
		margin-bottom: 14px;
	}

	.add-section {
		border: 1px dashed var(--border);
		border-radius: var(--r);
		background: var(--sunken, var(--surface));
		padding: 12px;
		margin-bottom: 16px;
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

	.opt {
		display: flex;
		flex-direction: column;
		min-width: 0;
	}

	.opt-label {
		font-size: 13px;
		color: var(--text);
	}

	.status {
		font-size: 13px;
		color: var(--text-3);
		margin: 6px 2px 0;
	}

	.empty-line {
		color: var(--text-3);
	}
</style>
