<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { page } from '$app/state';
	import { invalidateAll } from '$app/navigation';

	import PageHeader from '$lib/components/primitives/surfaces/PageHeader.svelte';
	import RoleAssignmentEditor from '$lib/components/features/admin/RoleAssignmentEditor.svelte';
	import { DocumentDataDriver } from '$lib/datasource/DocumentDriver.js';
	import { setSearchParams } from '$lib/utils/searchParams.js';
	import { onPermissionRefresh } from '$lib/authorization/permissionRefresh.svelte.js';
	import * as m from '$lib/paraglide/messages';

	/**
	 * Role assignment page — owns the URL state and the page chrome, and
	 * mounts `RoleAssignmentEditor` for the loaders, the search debounce, and
	 * the membership mutations. See the component for the mode and scaling
	 * notes.
	 *
	 * URL params (`?mode=`, `?role=`, `?account=`) make the view deep-linkable
	 * and survive reload and back/forward navigation.
	 */

	type Mode = 'role' | 'account';

	// ── URL state ────────────────────────────────────────────────────────
	const mode = $derived<Mode>(page.url.searchParams.get('mode') === 'account' ? 'account' : 'role');
	const selectedRole = $derived(page.url.searchParams.get('role') ?? '');
	const selectedAccount = $derived(page.url.searchParams.get('account') ?? '');

	function setUrl(next: Partial<{ mode: Mode; role: string; account: string }>) {
		const m = next.mode ?? mode;
		setSearchParams({
			mode: m,
			role: m === 'role' ? (next.role ?? selectedRole) : null,
			account: m === 'account' ? (next.account ?? selectedAccount) : null
		});
	}

	// The editor owns the loaders and the mutations. The driver is created
	// here and injected, so stories can mount a mock driver.
	const driver = new DocumentDataDriver('');

	// Reload the layout load data on the permission-refresh signal. The
	// editor reloads its own loaders on the same signal.
	onPermissionRefresh(() => {
		void invalidateAll();
	});
</script>

<svelte:head>
	<title>{m.configure_assignments_page_title()}</title>
</svelte:head>

<div class="page">
	<PageHeader
		title={m.configure_assignments_title()}
		subtitle={m.configure_assignments_subtitle()}
	/>

	<RoleAssignmentEditor
		{driver}
		{mode}
		{selectedRole}
		{selectedAccount}
		onnavigate={setUrl}
		onrefresh={invalidateAll}
	/>
</div>

<style>
	.page {
		padding: 28px 32px 48px;
		max-width: 960px;
		margin: 0 auto;
	}
</style>
