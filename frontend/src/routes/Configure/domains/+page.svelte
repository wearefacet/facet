<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import type { LayoutData } from '../$types';
</script>

<script lang="ts">
	import { page } from '$app/state';
	import { goto, invalidateAll, replaceState } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { apiFetch } from '$lib/session.svelte';
	import { DocumentDataDriver } from '$lib/datasource/DocumentDriver';
	import { domainListCache, documentShowCache } from '$lib/datasource/clientCache.js';
	import type { NavDomain } from '$lib/navTypes';
	import type { DomainImportReport } from '$lib/portableDomains/portableDomainsClient.js';
	import { can } from '$lib/permissions.svelte';
	import { clearDomainCounts } from '$lib/navCounts.svelte';
	import { onPermissionRefresh } from '$lib/authorization/permissionRefresh.svelte.js';
	import { Plus, GitBranch, Settings } from '@lucide/svelte';
	import Button from '$lib/components/primitives/actions/Button.svelte';
	import PageHeader from '$lib/components/primitives/surfaces/PageHeader.svelte';
	import AlertBanner from '$lib/components/primitives/content/AlertBanner.svelte';
	import DeleteDomainDialog from '$lib/components/features/configure/DeleteDomainDialog.svelte';
	import ImportDomainDialog from '$lib/components/features/configure/ImportDomainDialog.svelte';
	import DomainsList from '$lib/components/features/configure/DomainsList.svelte';
	import * as m from '$lib/paraglide/messages';

	/**
	 * Domain list landing — owns the published-domain data (layout load),
	 * the page chrome, the import / delete dialogs, and navigation. The
	 * draft lifecycle, the export flow, and the row actions live in
	 * `DomainsList`; the two sections it renders are drafts first, then
	 * published live domains, with a surface-1 band explaining where each
	 * kind of change happens: configuration applies to the live domain in
	 * place; shape changes branch a draft.
	 */

	let { data }: { data: LayoutData } = $props();

	// The driver the list component uses for its client-side draft loads.
	const driver = new DocumentDataDriver('');

	let newDomainDialogOpen = $state(false);
	let importOpen = $state(false);
	// The published domain row pending deletion (drives DeleteDomainDialog).
	let deleteTarget = $state<NavDomain | undefined>(undefined);
	let deleteDialogOpen = $state(false);
	// Draft load / create / discard errors — reported by the list
	// component's `ondrafterror` callback. The banner sits above the
	// explain band.
	let draftError = $state<string | undefined>(undefined);

	// ── Navigation ───────────────────────────────────────────────────────

	function openBuilder(draftId: string) {
		goto(resolve('/Builder/[draftDomain]/(editor)/overview', { draftDomain: draftId }));
	}

	function configureDomain(slug: string) {
		goto(resolve('/Configure/domains/[slug]', { slug }));
	}

	// ── Delete (published) ───────────────────────────────────────────────

	// Deletion of a published domain. Called by DeleteDomainDialog; returns
	// null on success (the dialog closes) or an error message string (shown
	// inline) matching the dialog's contract.
	async function deleteDomain(domainId: string): Promise<string | null> {
		try {
			const res = await apiFetch(`/Api/core/Domain/${domainId}/drop`, { method: 'POST' });
			if (!res.ok) {
				const body = await res.json().catch(() => ({}));
				return body.error ?? m.builder_draft_failed_status({ status: res.status });
			}
			// Drop every cache that still holds the deleted domain — the layout
			// load's domain list and the cached `show()` for the domain document
			// — then re-run the loaders so the row disappears without waiting
			// for the TTL.
			domainListCache.invalidate();
			documentShowCache.invalidate(`/Api/core/Domain/${domainId}`);
			await invalidateAll();
			return null;
		} catch {
			return m.configure_domains_network_delete_error();
		}
	}

	function openDeleteDialog(domain: NavDomain) {
		deleteTarget = domain;
		deleteDialogOpen = true;
	}

	// ── Import ───────────────────────────────────────────────────────────

	// Deep link (`/Configure/domains?import=1`, from the welcome tour and the
	// dashboard's empty-state card): open the import dialog on mount, then
	// strip the param so a reload does not re-open it. `replaceState` avoids a
	// navigation — no load re-runs, no scroll reset.
	$effect(() => {
		if (page.url.searchParams.get('import') !== '1') return;
		importOpen = true;
		const url = new URL(page.url.href);
		url.searchParams.delete('import');
		const rest = url.searchParams.toString();
		replaceState(resolve(rest ? `/Configure/domains?${rest}` : '/Configure/domains'), {});
	});

	// Called by ImportDomainDialog after a bundle imports: drop the cached
	// list and re-run the loaders so the new/updated domain appears at once.
	// The bundle also rewrites the target domain's doctypes out-of-band, so
	// the sidebar's per-doctype counts for it go stale — drop them, and the
	// fetch effect refetches them without a navigation (F02-02).
	async function refreshAfterImport(report: DomainImportReport) {
		clearDomainCounts(report.domain);
		domainListCache.invalidate();
		await invalidateAll();
	}

	// Reload the layout load data on the permission-refresh signal. The list
	// component reloads its drafts on the same signal.
	onPermissionRefresh(() => {
		invalidateAll();
	});
</script>

<svelte:head>
	<title>{m.configure_domains_page_title()}</title>
</svelte:head>

<div class="page">
	<PageHeader
		title={m.configure_domains_list_title()}
		subtitle={m.configure_domains_list_subtitle()}
	>
		{#snippet actions()}
			<!-- The import route gates fresh imports on `create core.Domain` and
				merge imports on `update` — the button shows for either. -->
			{#if can('core.Domain', 'create') || can('core.Domain', 'update')}
				<Button variant="secondary" onclick={() => (importOpen = true)}>
					{m.configure_domains_import_button()}
				</Button>
			{/if}
			<Button variant="primary" onclick={() => (newDomainDialogOpen = true)}>
				{#snippet iconLeft()}
					<Plus size={14} strokeWidth={2} aria-hidden="true" />
				{/snippet}
				{m.configure_domains_new_button()}
			</Button>
		{/snippet}
	</PageHeader>

	{#if draftError}
		<AlertBanner message={draftError} dismissable onDismiss={() => (draftError = undefined)} />
	{/if}

	<div class="explain">
		<div class="explain-item">
			<span class="explain-icon">
				<Settings size={16} aria-hidden="true" />
			</span>
			<div>
				<p class="explain-title">{m.configure_domains_explain_configure_title()}</p>
				<p class="explain-text">
					{m.configure_domains_explain_configure_text()}
				</p>
			</div>
		</div>
		<div class="explain-divider" aria-hidden="true"></div>
		<div class="explain-item">
			<span class="explain-icon accent">
				<GitBranch size={16} aria-hidden="true" />
			</span>
			<div>
				<p class="explain-title">{m.configure_domains_explain_draft_title()}</p>
				<p class="explain-text">
					{m.configure_domains_explain_draft_text()}
				</p>
			</div>
		</div>
	</div>

	<DomainsList
		domains={data.domains}
		{driver}
		onopenbuilder={openBuilder}
		onconfigure={configureDomain}
		ondelete={openDeleteDialog}
		bind:newDialogOpen={newDomainDialogOpen}
		ondrafterror={(message) => (draftError = message)}
	/>
</div>

<ImportDomainDialog bind:open={importOpen} onimported={refreshAfterImport} />

<DeleteDomainDialog
	bind:open={deleteDialogOpen}
	domain={deleteTarget ? { id: deleteTarget.id, label: deleteTarget.label } : undefined}
	ondeleted={deleteDomain}
/>

<style>
	.page {
		padding: 28px 32px 48px;
		max-width: 960px;
		margin: 0 auto;
	}

	/* ── Explain band ───────────────────────────────────────────────────── */
	.explain {
		display: flex;
		gap: 14px;
		background: var(--surface-1, var(--surface));
		border-radius: var(--r);
		padding: 12px 14px;
		margin-bottom: 22px;
	}

	.explain-item {
		flex: 1;
		display: flex;
		gap: 9px;
		min-width: 0;
	}

	.explain-icon {
		display: flex;
		color: var(--text-3);
		flex: none;
		margin-top: 1px;
	}

	.explain-icon.accent {
		color: var(--accent-ink);
	}

	.explain-title {
		margin: 0 0 2px;
		font-size: 13px;
		font-weight: 500;
		color: var(--text);
	}

	.explain-text {
		margin: 0;
		font-size: 12px;
		color: var(--text-3);
		line-height: 1.55;
	}

	.explain-divider {
		width: 1px;
		background: var(--border);
		flex: none;
	}
</style>
