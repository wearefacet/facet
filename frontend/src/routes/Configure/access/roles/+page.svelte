<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { page } from '$app/state';
	import { goto, invalidateAll } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { untrack } from 'svelte';

	import PageHeader from '$lib/components/primitives/surfaces/PageHeader.svelte';
	import AlertBanner from '$lib/components/primitives/content/AlertBanner.svelte';
	import RbacEditor from '$lib/components/features/admin/RbacEditor.svelte';
	import NewRoleDialog from '$lib/components/features/admin/NewRoleDialog.svelte';
	import type { RoleContent, PermissionRaw } from '$lib/components/features/admin/rbacModel.js';
	import { DocumentDataDriver } from '$lib/datasource/DocumentDriver.js';
	import { DoctypeRegistry } from '$lib/datasource/DoctypeRegistry.js';
	import { toBannerError, errorMessage } from '$lib/datasource/bannerError.js';
	import { humanizeRoleName } from '$lib/authorization/roleMembership.js';
	import type { AccountContent } from '$lib/iam/content.js';
	import { onPermissionRefresh } from '$lib/authorization/permissionRefresh.svelte.js';
	import { SvelteMap } from 'svelte/reactivity';
	import * as m from '$lib/paraglide/messages';

	/**
	 * Roles list — application-global role declarations.
	 *
	 * Roles are app-global (not domain-scoped); each role has Members
	 * (user-to-role) and Grants (per-domain doctype access). The roles
	 * list page hosts the RBAC editor: it picks a role, then edits that
	 * role's per-doctype permissions against the live doctype registry.
	 *
	 * The selected role is reflected in the `?role=` query param so the
	 * choice is shareable, deep-linkable, and survives reload and
	 * back/forward navigation. Saving writes the `permissions` field back
	 * to the `iam.Roles` document via a standard update mutation.
	 *
	 * Draft domains and their doctypes are excluded from the editor: a
	 * draft's doctype shape is not authoritative until published, so
	 * granting permissions against it would be misleading. The member
	 * count per role is computed from `iam.Account.roles` (array membership).
	 */

	type RoleListItem = { data: RoleContent };
	type AccountListItem = { data: AccountContent; meta: { id: string } };

	let registry = $state<Map<string, Record<string, unknown>>>(new Map());
	let roles = $state<RoleListItem[]>([]);
	let domains = $state<{ id: string; data: Record<string, unknown> }[]>([]);
	let memberCountByRoleId = $state<Map<string, number>>(new Map());
	let loadError = $state<string | undefined>(undefined);
	let loaded = $state(false);

	// role `name` → document `meta.id`, so save/create/delete can target the
	// right `iam.Roles` document. Rebuilt on every load.
	let roleIdByName = $state<Map<string, string>>(new Map());

	// Selected role id (the role `name`). Seeded from `?role=` on mount;
	// updated by the editor's role picker when the user changes selection.
	// The URL-sync effect below reflects the choice into the address bar.
	let selectedRoleId = $state<string>(page.url.searchParams.get('role') ?? '');

	// Per-role assignment-page URL. The role document id is the qualified form
	// `iam.Roles.<name>`, matching the values stored on `iam.Account.roles`.
	// The assignments page reads `?mode=role&role=` from the URL, so a bare
	// `/assignments` would land unscoped — without a selection the link goes
	// to the unscoped page and the user picks there.
	const assignmentsRoute = $derived(
		selectedRoleId
			? resolve(
					`/Configure/access/assignments?mode=role&role=${encodeURIComponent(`iam.Roles.${selectedRoleId}`)}`
				)
			: resolve('/Configure/access/assignments')
	);

	// New-role dialog open state.
	let newRoleOpen = $state(false);

	// Single shared driver for all reads on this page (registry + roles +
	// domains + accounts). Same construction as `/Configure/domains`.
	const driver = new DocumentDataDriver('');

	async function loadAll() {
		try {
			const [reg, rolesRes, domainsRes, accountsRes] = await Promise.all([
				DoctypeRegistry.cached(driver),
				driver.domain('iam').doctype('Roles').list({ items: 500 }),
				driver.domain('core').doctype('Domain').list({ items: 500 }),
				driver.domain('iam').doctype('Account').list({ items: 10000 })
			]);

			// Exclude draft domains — their doctype shapes are not authoritative
			// until published. Keep both the domain cards and their doctypes out.
			const publishedDomains = domainsRes.data.filter((item) => item.data.draft !== true);
			const publishedDomainIds = new Set(publishedDomains.map((item) => item.meta.id));

			const filteredRegistry = untrack(() => new SvelteMap<string, Record<string, unknown>>());
			for (const [qualified, def] of reg.doctypeDefinitions) {
				const dot = qualified.indexOf('.');
				const domain = dot === -1 ? '' : qualified.slice(0, dot);
				if (publishedDomainIds.has(domain)) untrack(() => filteredRegistry.set(qualified, def));
			}

			registry = filteredRegistry;
			roles = rolesRes.data as unknown as RoleListItem[];
			roleIdByName = new Map(
				rolesRes.data.map((item) => [String(item.data.name ?? ''), item.meta.id])
			);
			domains = publishedDomains.map((item) => ({ id: item.meta.id, data: item.data }));

			// Member count per role: scan every account's `roles` array for the
			// role's document id, then key the count by role `name` (the editor and
			// picker operate on names). There is no array-contains filter on the
			// list API, so this is a client-side pass (mirrors the backend Lua
			// guard in data/seeds/iam.Roles/script.lua).
			const idToName = untrack(() => new SvelteMap<string, string>());
			for (const [name, id] of roleIdByName) idToName.set(id, name);
			const counts = untrack(() => new SvelteMap<string, number>());
			for (const acc of accountsRes.data as AccountListItem[]) {
				const arr = acc.data?.roles;
				if (!Array.isArray(arr)) continue;
				for (const rid of arr) {
					if (typeof rid !== 'string') continue;
					const name = idToName.get(rid);
					if (name) untrack(() => counts.set(name, (counts.get(name) ?? 0) + 1));
				}
			}
			memberCountByRoleId = counts;

			loadError = undefined;
		} catch (err) {
			loadError = errorMessage(err);
		} finally {
			loaded = true;
		}
	}

	$effect(() => {
		// Re-fetch when (re)entering the configure subtree.
		void page.url.pathname;
		loadAll();
	});

	// Reflect the selected role into the URL `?role=` param. The picker is
	// a filter, not a navigation, so it uses `replaceState` (no history spam).
	// The param is cleared when nothing is selected so the URL stays tidy.
	// Deep-linkable: a shared/reloaded URL restores the selection on mount.
	$effect(() => {
		const current = page.url.searchParams.get('role') ?? '';
		if (current === selectedRoleId) return;
		const search = selectedRoleId ? `?role=${encodeURIComponent(selectedRoleId)}` : '';
		goto(resolve(`/Configure/access/roles${search}`), { replaceState: true, noScroll: true });
	});

	// Reload roles on permission refresh (matches the configure layout).
	onPermissionRefresh(() => {
		void loadAll();
		invalidateAll();
	});

	// Persist the edited `permissions` array back to the `iam.Roles` document.
	// A standard update mutation replaces the `permissions` field; the editor's
	// dirty flag clears once the refreshed `roles` prop lands (the host
	// invalidates the document cache so the next read sees the new value).
	async function saveRole(roleName: string, permissions: PermissionRaw[]): Promise<void> {
		const docId = roleIdByName.get(roleName);
		if (!docId)
			throw new Error(m.configure_roles_save_missing({ name: humanizeRoleName(roleName) }));
		await driver.domain('iam').doctype('Roles').doc(docId).update({ permissions });
		// Refresh roles so the editor's saved snapshot matches the working copy.
		await loadAll();
		await invalidateAll();
	}

	// Create a new role document with no permissions. The iam.Roles definition
	// seeds `visible_tags` with ['default']; we keep the same default so the
	// role is visible under the standard tag without extra configuration.
	// The required level arrives validated from the dialog (integer 0–100)
	// and is forwarded as-is. The optional description is forwarded as-is
	// (the field is `longtext`).
	// On failure, the structured `DataSourceError.details` array is returned
	// so the dialog can show `name — must be unique, ...` instead of the bare
	// headline `Document validation failed`
	async function createRole(
		name: string,
		description: string,
		level: number
	): Promise<string | { message: string; details: string[] } | null> {
		try {
			const content: Record<string, unknown> = {
				name,
				level,
				permissions: [],
				visible_tags: ['default']
			};
			if (description) content.description = description;
			await driver.domain('iam').doctype('Roles').create(content);
			await loadAll();
			selectedRoleId = name;
			return null;
		} catch (err) {
			const banner = toBannerError(err);
			return banner.details.length > 0 ? banner : banner.message;
		}
	}

	// Delete the named role. The backend Lua guard refuses when any account
	// still holds the role (data/seeds/iam.Roles/script.lua); the editor also
	// disables the button when `memberCount > 0`, but the server-side check is
	// the source of truth.
	async function deleteRole(roleName: string): Promise<void> {
		const docId = roleIdByName.get(roleName);
		if (!docId)
			throw new Error(m.configure_roles_delete_missing({ name: humanizeRoleName(roleName) }));
		await driver.domain('iam').doctype('Roles').doc(docId).delete();
		if (selectedRoleId === roleName) selectedRoleId = '';
		await loadAll();
		await invalidateAll();
	}
</script>

<svelte:head>
	<title>{m.configure_roles_page_title()}</title>
</svelte:head>

<div class="page">
	<PageHeader title={m.configure_roles_title()} subtitle={m.configure_roles_subtitle()} />

	{#if loadError}
		<AlertBanner message={loadError} dismissable onDismiss={() => (loadError = undefined)} />
	{/if}

	{#if !loaded}
		<p class="status">{m.configure_roles_loading()}</p>
	{:else if registry.size > 0}
		<RbacEditor
			{registry}
			{roles}
			{domains}
			bind:selectedRoleId
			onsave={saveRole}
			onnew={() => (newRoleOpen = true)}
			ondelete={deleteRole}
			memberCountByRoleName={memberCountByRoleId}
			{assignmentsRoute}
		/>
	{:else}
		<p class="status">{m.configure_roles_no_registry()}</p>
	{/if}

	<NewRoleDialog bind:open={newRoleOpen} oncreate={createRole} />
</div>

<style>
	.page {
		padding: 28px 32px 48px;
		max-width: 1100px;
		margin: 0 auto;
	}

	.status {
		font-size: 13px;
		color: var(--text-3);
	}
</style>
