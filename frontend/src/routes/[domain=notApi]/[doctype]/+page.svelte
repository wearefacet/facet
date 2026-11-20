<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { Plus } from '@lucide/svelte';
	import { page } from '$app/state';
	import ListView from '$lib/components/primitives/data/ListView.svelte';
	import Button from '$lib/components/primitives/actions/Button.svelte';
	import Can from '$lib/components/primitives/surfaces/Can.svelte';
	import DoctypeIcon from '$lib/components/primitives/data/DoctypeIcon.svelte';
	import ImportExportActions from '$lib/components/features/importExport/ImportExportActions.svelte';
	import { setSearchParams } from '$lib/utils/searchParams.js';
	import { parseFilterParams } from '$lib/datasource/filterParams.js';
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { can } from '$lib/permissions.svelte';
	import { invalidateCount } from '$lib/navCounts.svelte';
	import { isTypingTarget, registerRouteShortcuts } from '$lib/shortcuts.svelte';
	import { subscribeCollectionRefresh } from '$lib/listSocket.svelte.js';
	import { isPreviewActive } from '$lib/previewSession.svelte';
	import * as m from '$lib/paraglide/messages';

	let { data } = $props();

	const def = $derived(data.def);
	const driver = $derived(data.driver);
	const parentDocId = $derived(data.parentDocTypeId);
	const viewerId = $derived(data.account?.id);
	const qualifiedName = $derived(data.qualifiedName as string);

	const newHref = $derived(
		`/${encodeURIComponent(def.domain)}/${encodeURIComponent(def.doctype)}/new`
	);

	// Bumped by the import dialog's completion callback (through the toolbar
	// snippet) and by the live collection subscription so the listing
	// refetches and the new rows show at once (B-106: the list kept the
	// pre-import rows until a manual reload).
	let listingRefresh = $state(0);

	function refreshListing(): void {
		listingRefresh++;
	}

	// Trash mode — a listing mode, not a saved view: `CollectionView` does not
	// carry a `deleted` flag, so the toggle lives in the page head and rides
	// the `?deleted=` URL param (mirroring the `?view=` deep-link precedent).
	const includeDeleted = $derived(page.url.searchParams.get('deleted') === 'true');

	function setTrashMode(on: boolean): void {
		setSearchParams({ deleted: on ? 'true' : null });
	}

	// B-376 — `filters[key__op]=value` deep links seed the listing. They map
	// 1:1 onto the DataSource filter shape, so a filtered listing is shareable
	// without a saved view. Precedence rule: URL filters apply only when no
	// `?view=` is present — a saved-view deep link keeps its own tab
	// configuration authoritative.
	// The derived hands out a stable object per distinct param set: the Table
	// drops its in-flight toolbar state when the `filters` prop changes
	// identity, so an unrelated URL write (trash toggle, tab switch) must not
	// produce a fresh map. The plain-`let` shadows are derivation-internal
	// memo keys — never read elsewhere (workflow doc → equality-guard trap).
	const EMPTY_FILTERS: Record<string, unknown> = {};
	let lastFiltersSig = '';
	let lastFilters = EMPTY_FILTERS;
	const urlFilters = $derived.by(() => {
		const params = page.url.searchParams;
		if (params.has('view')) return EMPTY_FILTERS;
		let sig = '';
		for (const [key, value] of params) {
			if (key.startsWith('filters[')) sig += `${key}=${value}&`;
		}
		if (sig === lastFiltersSig) return lastFilters;
		lastFiltersSig = sig;
		lastFilters = sig === '' ? EMPTY_FILTERS : parseFilterParams(params);
		return lastFilters;
	});

	// `C` creates a new record of this doctype — the web-safe "new" shortcut
	// (Ctrl/Cmd+N is reserved by the browsers). Registration is gated on the
	// create permission, mirroring the rendered New button; the handler
	// resolves the route at keypress time from the URL params.
	$effect(() => {
		if (!can(qualifiedName, 'create')) return;
		return registerRouteShortcuts([
			{
				id: 'list.new',
				keys: 'C',
				label: m.shortcuts_list_new(),
				group: 'list',
				when: (e) => !isTypingTarget(e.target),
				handler: () => {
					void goto(
						resolve('/[domain=notApi]/[doctype]/new', {
							domain: page.params.domain ?? def.domain,
							doctype: page.params.doctype ?? def.doctype
						})
					);
					return true;
				}
			}
		]);
	});

	// Live listing refresh: the doctype's collection channel re-runs the
	// listing query when any actor mutates this doctype — through the same
	// `refreshSignal` seam as the import completion, so the current view,
	// filters, and paging ride the re-query. Skipped during a builder
	// preview session: the socket carries the real principal, so the draft
	// domain's collection subscribe would be rejected; manual refresh stays.
	// Navigation to another listing resubscribes through the effect deps.
	$effect(() => {
		if (typeof window === 'undefined') return;
		if (isPreviewActive()) return;
		return subscribeCollectionRefresh({
			domain: def.domain,
			docType: def.doctype,
			refresh: refreshListing
		});
	});
</script>

<svelte:head>
	<title>{m.list_page_title({ doctype: def.doctype, domain: def.domain })}</title>
</svelte:head>

<div class="doctype-page">
	<div class="doctype-head">
		<DoctypeIcon icon={def.icon} color={def.color} />
		<h1>{def.doctype}</h1>
		<span class="head-sub">{def.domain}.{def.doctype}</span>
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
		<Can doctype={qualifiedName} action="create">
			<Button href={newHref} variant="primary" size="sm">
				{#snippet iconLeft()}
					<Plus size={14} strokeWidth={2} aria-hidden="true" />
				{/snippet}
				{m.doc_new_button()}
			</Button>
		</Can>
	</div>

	<div class="doctype-body">
		<ListView
			{driver}
			doctype={def}
			{parentDocId}
			{viewerId}
			{includeDeleted}
			filters={urlFilters}
			refreshSignal={listingRefresh}
		>
			{#snippet toolbarActions(args)}
				<Can doctype={qualifiedName} action="read">
					<ImportExportActions
						domain={def.domain}
						doctype={def.doctype}
						onimported={() => {
							// The import wrote rows without a count update. Drop the
							// sidebar's cached count for this doctype, so the badge
							// refetches (F02-02). The key is the doctype id — the same
							// shape the nav model uses, not the URL label.
							invalidateCount(`${def.domain}.${def.doctype}`);
							listingRefresh++;
						}}
						view={!includeDeleted
							? {
									columns: args.columns.map((c) => c.key).filter((k) => !k.startsWith('__')),
									filters: args.filters,
									sort: args.sort ? [`${args.sort.desc ? '-' : ''}${args.sort.key}`] : []
								}
							: null}
					/>
				</Can>
			{/snippet}
		</ListView>
	</div>
</div>

<style>
	.doctype-page {
		position: relative;
		height: 100%;
		min-height: 0;
		display: flex;
		flex-direction: column;
	}

	.doctype-head {
		display: flex;
		align-items: center;
		gap: 10px;
		padding: 24px 24px 0;
		flex-wrap: wrap;
	}

	.doctype-head h1 {
		font-family: var(--font-display);
		font-size: 22px;
		font-weight: 600;
		letter-spacing: -0.01em;
	}

	.head-sub {
		font-family: var(--font-mono);
		font-size: 12px;
		color: var(--text-3);
		margin-left: auto;
	}

	.trash-toggle {
		display: inline-flex;
		border: 1px solid var(--border);
		border-radius: var(--r-sm);
		overflow: hidden;
		margin-left: auto;
	}

	.head-sub + .trash-toggle {
		margin-left: 0;
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

	.doctype-body {
		flex: 1;
		min-height: 0;
		overflow: auto;
		padding: 20px 24px 24px;
	}
</style>
