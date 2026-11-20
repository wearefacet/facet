<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { page } from '$app/state';
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import type { LayoutData } from './$types';
	import { confirm } from '$lib/confirm.svelte';
	import { hasUnsavedEdits } from '$lib/unsavedEdits.js';
	import { roleDocIdToName, humanizeRoleName } from '$lib/authorization/roleMembership.js';
	import * as m from '$lib/paraglide/messages';

	/**
	 * Role detail layout — owns the Members / Grants tabs and renders
	 * the active tab's child page. The role id and active-tab derivation
	 * come from the URL, so navigation is shareable.
	 *
	 * Tab clicks must not discard a child's unsaved draft (the Details
	 * form, the grants editor): when the shared unsaved-edits gate reports
	 * a dirty child, the click confirms before navigating. A clean or
	 * same-tab click keeps the plain anchor behaviour — modified clicks
	 * (new tab, new window) are never intercepted.
	 */

	let { data: _data, children }: { data: LayoutData; children: import('svelte').Snippet } =
		$props();

	let roleId = $derived(page.params.id!);
	const roleName = $derived(humanizeRoleName(roleDocIdToName(roleId)));
	let tab = $derived<'details' | 'members' | 'grants'>(
		page.url.pathname.endsWith('/grants')
			? 'grants'
			: page.url.pathname.endsWith('/members')
				? 'members'
				: 'details'
	);

	async function onTabClick(event: MouseEvent, target: 'details' | 'members' | 'grants') {
		// Same-tab navigation remounts nothing — never confirm for it.
		if (target === tab) return;
		if (!hasUnsavedEdits()) return;
		if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey)
			return;
		event.preventDefault();
		if (
			!(await confirm({
				title: m.admin_confirm_discard_title(),
				message: m.admin_confirm_discard_leave({ current: roleName }),
				confirmLabel: m.admin_discard_button(),
				variant: 'danger'
			}))
		)
			return;
		if (target === 'details')
			await goto(resolve('/Configure/access/roles/[id]/details', { id: roleId }));
		else if (target === 'members')
			await goto(resolve('/Configure/access/roles/[id]/members', { id: roleId }));
		else await goto(resolve('/Configure/access/roles/[id]/grants', { id: roleId }));
	}
</script>

<svelte:head>
	<title>{m.configure_role_page_title({ name: roleId })}</title>
</svelte:head>

<div class="page">
	<div class="head">
		<h1>{m.configure_role_heading({ name: roleId })}</h1>
	</div>

	<div class="tabs">
		<a
			href={resolve('/Configure/access/roles/[id]/details', { id: roleId })}
			class:on={tab === 'details'}
			onclick={(e) => onTabClick(e, 'details')}>{m.configure_role_details_tab()}</a
		>
		<a
			href={resolve('/Configure/access/roles/[id]/members', { id: roleId })}
			class:on={tab === 'members'}
			onclick={(e) => onTabClick(e, 'members')}>{m.configure_role_members_tab()}</a
		>
		<a
			href={resolve('/Configure/access/roles/[id]/grants', { id: roleId })}
			class:on={tab === 'grants'}
			onclick={(e) => onTabClick(e, 'grants')}>{m.configure_domains_tab_grants()}</a
		>
	</div>

	<div class="tab-body">
		{@render children?.()}
	</div>
</div>

<style>
	.page {
		padding: 28px 32px 48px;
		max-width: 960px;
		margin: 0 auto;
	}
	.head {
		margin-bottom: 18px;
	}
	h1 {
		font-family: var(--font-display);
		font-size: 20px;
		font-weight: 600;
		color: var(--text);
	}
	.tabs {
		display: flex;
		gap: 4px;
		border-bottom: 1px solid var(--border);
		margin-bottom: 20px;
	}
	.tabs a {
		padding: 7px 14px;
		font-size: 13px;
		color: var(--text-3);
		text-decoration: none;
		border-bottom: 2px solid transparent;
	}
	.tabs a.on {
		color: var(--text);
		border-bottom-color: var(--accent);
	}
	.tab-body {
		min-height: 0;
	}
</style>
