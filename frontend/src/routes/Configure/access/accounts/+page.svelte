<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { Plus } from '@lucide/svelte';
	import { page } from '$app/state';

	import PageHeader from '$lib/components/primitives/surfaces/PageHeader.svelte';
	import Button from '$lib/components/primitives/actions/Button.svelte';
	import Can from '$lib/components/primitives/surfaces/Can.svelte';
	import ListView from '$lib/components/primitives/data/ListView.svelte';
	import { setSearchParams } from '$lib/utils/searchParams.js';
	import * as m from '$lib/paraglide/messages';

	/**
	 * Accounts — the admin surface over `iam.Account`.
	 *
	 * Accounts are ordinary documents, so the page renders the standard
	 * listing stack: the default `ListView` (tab-less — no saved-view strip,
	 * columns from the doctype's fallback rule) with the shared filter
	 * toolbar (search over `email` + `name`, filter chips for
	 * `email` / `status` / `organizational_unit`), sorting, pagination, and
	 * the QuickView peek on row click. Create and edit are the standard
	 * document form routes; the credential bootstrap actions (invite,
	 * temporary password, MFA reset) live on the account show page.
	 */

	let { data } = $props();

	const def = $derived(data.def);
	const driver = $derived(data.driver);
	const parentDocId = $derived(data.parentDocTypeId);

	// The create form returns here after saving (`?from=`), so a new account
	// lands back in Configure instead of the app-domain show page.
	const newHref = $derived(`/iam/Account/new?from=${encodeURIComponent(page.url.pathname)}`);

	// Trash mode — a listing mode, not a saved view: the toggle rides the
	// `?deleted=` URL param (mirroring the live doctype listing page).
	const includeDeleted = $derived(page.url.searchParams.get('deleted') === 'true');

	function setTrashMode(on: boolean): void {
		setSearchParams({ deleted: on ? 'true' : null });
	}
</script>

<svelte:head>
	<title>{m.configure_accounts_page_title()}</title>
</svelte:head>

<div class="page">
	<PageHeader title={m.configure_accounts_title()} subtitle={m.configure_accounts_subtitle()}>
		{#snippet actions()}
			<div class="trash-toggle" role="group" aria-label={m.configure_listing_mode_aria()}>
				<button
					class="trash-seg"
					class:seg-on={!includeDeleted}
					aria-pressed={!includeDeleted}
					onclick={() => setTrashMode(false)}>{m.configure_listing_live()}</button
				>
				<button
					class="trash-seg"
					class:seg-on={includeDeleted}
					aria-pressed={includeDeleted}
					onclick={() => setTrashMode(true)}>{m.common_deleted()}</button
				>
			</div>
			<Can doctype="iam.Account" action="create">
				<Button href={newHref} variant="primary" size="sm">
					{#snippet iconLeft()}
						<Plus size={14} strokeWidth={2} aria-hidden="true" />
					{/snippet}
					{m.configure_accounts_new_button()}
				</Button>
			</Can>
		{/snippet}
	</PageHeader>

	<ListView {driver} doctype={def} {parentDocId} showTabs={false} {includeDeleted} />
</div>

<style>
	.page {
		padding: 28px 32px 48px;
		max-width: 1400px;
		margin: 0 auto;
	}

	.trash-toggle {
		display: inline-flex;
		border: 1px solid var(--border);
		border-radius: var(--r-sm);
		overflow: hidden;
	}

	.trash-seg {
		font-family: var(--font-sans);
		font-size: 12px;
		font-weight: 600;
		color: var(--text-2);
		background: transparent;
		border: none;
		padding: 5px 12px;
		cursor: pointer;
	}

	.trash-seg:hover {
		background: var(--surface-2);
	}

	.trash-seg.seg-on {
		background: var(--surface-2);
		color: var(--text);
	}
</style>
