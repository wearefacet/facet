<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { page } from '$app/state';
	import { goto, invalidateAll } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { untrack } from 'svelte';
	import { SvelteMap } from 'svelte/reactivity';

	import PageHeader from '$lib/components/primitives/surfaces/PageHeader.svelte';
	import AlertBanner from '$lib/components/primitives/content/AlertBanner.svelte';
	import RbacEditor from '$lib/components/features/admin/RbacEditor.svelte';
	import type { PermissionRaw } from '$lib/components/features/admin/rbacModel.js';
	import { DocumentDataDriver } from '$lib/datasource/DocumentDriver.js';
	import { DoctypeRegistry } from '$lib/datasource/DoctypeRegistry.js';
	import { roleDocIdToName, humanizeRoleName } from '$lib/authorization/roleMembership.js';
	import { errorMessage } from '$lib/datasource/bannerError.js';
	import { onPermissionRefresh } from '$lib/authorization/permissionRefresh.svelte.js';
	import type { RoleContent } from '$lib/iam/content.js';
	import * as m from '$lib/paraglide/messages';

	/**
	 * Role grants page — per-doctype permissions for one role.
	 *
	 * This is the same `RbacEditor` component used by the roles list page
	 * (`/Configure/access/roles`), scoped to the role named in the URL. The
	 * URL carries the qualified role document id (`iam.Roles.<name>`); the
	 * editor's `selectedRoleId` is the bare `name`. When the picker switches
	 * role, the URL is updated so the choice is deep-linkable and survives
	 * reload — the page then refetches that role's document.
	 *
	 * Draft domains and their doctypes are excluded: a draft's doctype shape
	 * is not authoritative until published, so granting against it would be
	 * misleading (same rule as the roles list page).
	 *
	 * Saving writes the `permissions` field back to the `iam.Roles` document
	 * via a standard update mutation. No create / delete affordances are
	 * surfaced here — those live on the roles list page (which owns the
	 * collection-level flows).
	 */

	type RoleListItem = { data: RoleContent; meta: { id: string } };

	const urlRoleId = $derived(page.params.id ?? '');
	const urlRoleName = $derived(roleDocIdToName(urlRoleId));
	const headingRoleName = $derived(humanizeRoleName(urlRoleName));

	// Editor's `selectedRoleId` is the bare role `name`; the roles list page
	// binds this to a local state and reflects it into `?role=`. Here, the URL
	// is the source of truth (the path segment carries the qualified id), so
	// a writable derived reads the URL-derived name until the editor's picker
	// `bind:` assigns an override — and the URL-sync effect below navigates,
	// which changes `urlRoleName` and drops the override. This replaces the
	// `$state` + re-seed `$effect` pair (tripped `svelte/prefer-writable-derived`).
	let selectedRoleId = $derived(urlRoleName);

	let registry = $state<Map<string, Record<string, unknown>>>(new Map());
	let roles = $state<RoleListItem[]>([]);
	let domains = $state<{ id: string; data: Record<string, unknown> }[]>([]);
	let loadError = $state<string | undefined>(undefined);
	let loaded = $state(false);

	const driver = new DocumentDataDriver('');

	async function loadAll() {
		try {
			// Fetch the registry, the role document for the URL's role id, and
			// the published domains (draft domains are excluded from the editor).
			// The roles list page passes ALL roles to the picker; here we pass
			// only the one named in the URL, so the picker reflects the active
			// scope. When the user switches via the picker, the URL changes and
			// this effect refetches the new role.
			const qualId = `iam.Roles.${urlRoleName}`;
			const [reg, roleRes, domainsRes] = await Promise.all([
				DoctypeRegistry.cached(driver),
				driver.domain('iam').doctype('Roles').list({ items: 500 }),
				driver.domain('core').doctype('Domain').list({ items: 500 })
			]);

			// Pick only the role matching the URL — fall back to an empty list
			// (so `loadedRole` stays null harmlessly if the role id is stale).
			roles = (roleRes.data as unknown as RoleListItem[]).filter(
				(r) => `iam.Roles.${r.data.name ?? ''}` === qualId
			);

			const publishedDomains = domainsRes.data.filter((item) => item.data.draft !== true);
			const publishedDomainIds = new Set(publishedDomains.map((item) => item.meta.id));
			const filteredRegistry = untrack(() => new SvelteMap<string, Record<string, unknown>>());
			for (const [qualified, def] of reg.doctypeDefinitions) {
				const dot = qualified.indexOf('.');
				const domain = dot === -1 ? '' : qualified.slice(0, dot);
				if (publishedDomainIds.has(domain)) untrack(() => filteredRegistry.set(qualified, def));
			}
			registry = filteredRegistry;
			domains = publishedDomains.map((item) => ({ id: item.meta.id, data: item.data }));

			loadError = undefined;
		} catch (err) {
			loadError = errorMessage(err);
		} finally {
			loaded = true;
		}
	}

	$effect(() => {
		// Re-fetch when the role id in the URL changes (picker switch, back/forward).
		void page.url.pathname;
		void urlRoleId;
		loadAll();
	});

	// Reload on permission refresh (matches the roles list page).
	onPermissionRefresh(() => {
		void loadAll();
		invalidateAll();
	});

	// Reflect the editor's `selectedRoleId` into the URL when the picker
	// switches role. `goto` updates the path segment; the `$effect` watching
	// `urlRoleId` then re-seeds `selectedRoleId` and refetches the role doc.
	// `replaceState: false` so back/forward tracks picker switches.
	$effect(() => {
		if (!selectedRoleId || selectedRoleId === urlRoleName) return;
		goto(resolve('/Configure/access/roles/[id]/grants', { id: `iam.Roles.${selectedRoleId}` }), {
			replaceState: false,
			noScroll: true
		});
	});

	// Persist the edited `permissions` array back to the `iam.Roles` document.
	// Same contract as the roles list page's `saveRole`. The document id is the
	// qualified form `iam.Roles.<name>`.
	async function saveRole(roleName: string, permissions: PermissionRaw[]): Promise<void> {
		await driver
			.domain('iam')
			.doctype('Roles')
			.doc(`iam.Roles.${roleName}`)
			.update({ permissions });
		await loadAll();
		await invalidateAll();
	}
</script>

<svelte:head>
	<title>{m.configure_role_grants_page_title({ name: headingRoleName })}</title>
</svelte:head>

<div class="page">
	<PageHeader
		title={m.configure_domains_tab_grants()}
		subtitle={m.configure_role_grants_subtitle()}
	/>

	{#if loadError}
		<AlertBanner message={loadError} dismissable onDismiss={() => (loadError = undefined)} />
	{/if}

	{#if !loaded}
		<p class="status">{m.configure_role_grants_loading()}</p>
	{:else if registry.size > 0}
		<RbacEditor {registry} {roles} {domains} bind:selectedRoleId onsave={saveRole} />
	{:else}
		<p class="status">{m.configure_roles_no_registry()}</p>
	{/if}
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
