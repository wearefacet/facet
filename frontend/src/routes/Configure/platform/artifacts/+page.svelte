<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import PageHeader from '$lib/components/primitives/surfaces/PageHeader.svelte';
	import QuickViewHost from '$lib/components/primitives/surfaces/QuickViewHost.svelte';
	import ArtifactsExplorer from '$lib/components/features/platform/ArtifactsExplorer.svelte';
	import { DocumentDataDriver } from '$lib/datasource/DocumentDriver.js';
	import type { DoctypeDef } from '$lib/doctype/types.js';
	import {
		listArtifacts,
		listArtifactGrants,
		listArtifactReferences,
		revokeArtifactGrant,
		purgeArtifact,
		ArtifactsError,
		type ArtifactRow,
		type ArtifactGrantRow,
		type ArtifactReferenceRow
	} from '$lib/components/features/platform/ArtifactsSource.js';
	import { errorMessage as toMessage } from '$lib/datasource/bannerError.js';
	import { confirm, confirmWithText } from '$lib/confirm.svelte';
	import { can } from '$lib/permissions.svelte.js';
	import * as m from '$lib/paraglide/messages';

	/**
	 * Artifact management page (/Configure/platform/artifacts).
	 *
	 * The page owns all state: the listing (filters / pagination, same
	 * request-sequence guard as the indexes page) and the detail panel of
	 * the selected artifact (grants + references, refetched on selection).
	 * Revocation asks for confirmation, calls the shared grant route, and
	 * refreshes the grants list plus the listing (the live-grant count in
	 * the row changes). The backend re-checks every call; the revoke button
	 * renders only for roles holding the `revoke *.*` operator action.
	 *
	 * The detail header links to the download gateway (view inline for
	 * browser-safe MIME types, download otherwise) and offers force delete
	 * for roles holding the `purge *.*` operator action — a security
	 * deletion whose confirm dialog captures an optional reason that lands
	 * on the backend's `iam.ArtifactEvent` audit record.
	 *
	 * A `QuickViewHost` wraps the layout so the account capsules (grants)
	 * and the resource capsules (references) open the peek drawer — the
	 * same pattern as the audit page.
	 */

	const PAGE_SIZE = 50;

	let filters: Record<string, unknown> = $state({});
	let page: number = $state(1);
	let data = $state<{ data: ArtifactRow[]; meta: { count: number; more: boolean } } | null>(null);
	let loading: boolean = $state(true);
	let refreshing: boolean = $state(false);
	let errorMessage: string | undefined = $state(undefined);
	let errorStatus: number | undefined = $state(undefined);

	let selected: ArtifactRow | null = $state(null);
	let grants = $state<ArtifactGrantRow[]>([]);
	let grantsMeta = $state<{ count: number; more: boolean } | null>(null);
	let references = $state<ArtifactReferenceRow[]>([]);
	let referencesMeta = $state<{ count: number; more: boolean } | null>(null);
	let detailLoading: boolean = $state(false);
	let detailError: string | undefined = $state(undefined);
	let busyGrantId: string | null = $state(null);
	let purging: boolean = $state(false);

	const canRevoke = $derived(can('*.*', 'revoke'));
	const canPurge = $derived(can('*.*', 'purge'));

	// Single shared driver for the peek drawer and the capsule hydration.
	// Same construction as the audit page.
	const driver = new DocumentDataDriver('');

	// The page has no host doctype — the stub is only read by `QuickViewHost`
	// on a root open (`openRootDoc`), which this page never issues; opens go
	// through `openReference`.
	const ROOT_DEF: DoctypeDef = {
		domain: 'core',
		doctype: 'DocType',
		fields: [],
		children: [],
		actions: []
	};

	// Request sequence — a slow response must never overwrite a newer one
	// (per-keystroke text filters can interleave fetches).
	let loadSeq = 0;
	let detailSeq = 0;

	async function load() {
		const my = ++loadSeq;
		loading = true;
		errorMessage = undefined;
		errorStatus = undefined;
		try {
			const res = await listArtifacts({ page, items: PAGE_SIZE, filters, sort: ['-created_at'] });
			if (my !== loadSeq) return;
			data = res;
			// Drop the detail panel when the selected artifact left the page
			// (deleted rows list only under the "Deleted" state filter).
			const current = selected;
			if (current && !res.data.some((row) => row.id === current.id)) {
				select(null);
			}
		} catch (e) {
			if (my !== loadSeq) return;
			data = null;
			if (e instanceof ArtifactsError) {
				errorStatus = e.status;
				errorMessage = e.status === 403 ? m.platform_artifacts_forbidden() : e.message;
			} else {
				errorMessage = toMessage(e, m.platform_artifacts_load_error());
			}
		} finally {
			if (my === loadSeq) loading = false;
		}
	}

	async function loadDetail(artifactId: string) {
		const my = ++detailSeq;
		detailLoading = true;
		detailError = undefined;
		try {
			const [g, r] = await Promise.all([
				listArtifactGrants(artifactId),
				listArtifactReferences(artifactId)
			]);
			if (my !== detailSeq) return;
			grants = g.data;
			grantsMeta = g.meta;
			references = r.data;
			referencesMeta = r.meta;
		} catch (e) {
			if (my !== detailSeq) return;
			grants = [];
			references = [];
			grantsMeta = null;
			referencesMeta = null;
			detailError =
				e instanceof ArtifactsError && e.status === 404
					? m.platform_artifacts_load_error()
					: toMessage(e, m.platform_artifacts_detail_load_error());
		} finally {
			if (my === detailSeq) detailLoading = false;
		}
	}

	function select(row: ArtifactRow | null) {
		selected = row;
		if (row) {
			void loadDetail(row.id);
		} else {
			grants = [];
			references = [];
			grantsMeta = null;
			referencesMeta = null;
			detailError = undefined;
		}
	}

	// Reload whenever filters or page change (and on mount).
	$effect(() => {
		void filters;
		void page;
		void load();
	});

	async function refresh() {
		refreshing = true;
		try {
			await load();
			if (selected) await loadDetail(selected.id);
		} finally {
			refreshing = false;
		}
	}

	async function handleRevoke(grant: ArtifactGrantRow) {
		const ok = await confirm({
			title: m.platform_artifacts_revoke_confirm_title(),
			message: m.platform_artifacts_revoke_confirm_message(),
			confirmLabel: m.platform_artifacts_revoke_confirm_button(),
			variant: 'danger'
		});
		if (!ok) return;

		busyGrantId = grant.id;
		detailError = undefined;
		try {
			await revokeArtifactGrant(grant.id);
			if (selected) await loadDetail(selected.id);
			await load();
		} catch (e) {
			detailError =
				e instanceof ArtifactsError && e.status === 403
					? m.platform_artifacts_revoke_forbidden()
					: toMessage(e, m.platform_artifacts_revoke_error());
		} finally {
			busyGrantId = null;
		}
	}

	/**
	 * Force delete (security deletion). The confirm dialog captures an
	 * optional reason — it rides to the backend and lands on the
	 * `iam.ArtifactEvent` audit record. After a successful purge the row is
	 * gone from the store, so the selection clears and the list reloads.
	 */
	async function handlePurge(row: ArtifactRow) {
		const answer = await confirmWithText({
			title: m.platform_artifacts_purge_confirm_title(),
			message: m.platform_artifacts_purge_confirm_message(),
			confirmLabel: m.platform_artifacts_purge_confirm_button(),
			variant: 'danger',
			prompt: {
				label: m.platform_artifacts_purge_reason_label(),
				placeholder: m.platform_artifacts_purge_reason_placeholder()
			}
		});
		if (!answer.ok) return;

		purging = true;
		detailError = undefined;
		try {
			await purgeArtifact(row.id, answer.text);
			select(null);
			await load();
		} catch (e) {
			detailError =
				e instanceof ArtifactsError && e.status === 403
					? m.platform_artifacts_purge_forbidden()
					: toMessage(e, m.platform_artifacts_purge_error());
		} finally {
			purging = false;
		}
	}
</script>

<svelte:head>
	<title>{m.platform_artifacts_page_title()}</title>
</svelte:head>

<div class="page">
	<PageHeader
		title={m.platform_artifacts_page_header()}
		subtitle={m.platform_artifacts_page_subtitle()}
	/>

	{#if errorMessage && errorStatus === 403}
		<div class="state state-error">
			<p>{errorMessage}</p>
		</div>
	{:else if errorMessage}
		<div class="state state-error">
			<p>{errorMessage}</p>
			<button class="retry-btn" type="button" onclick={load}>{m.common_retry()}</button>
		</div>
	{:else}
		<QuickViewHost {driver} rootDef={ROOT_DEF} rootParentDocId="core.DocType">
			{#snippet trigger(api)}
				<ArtifactsExplorer
					items={data?.data ?? []}
					{loading}
					meta={data?.meta ?? null}
					{page}
					pageSize={PAGE_SIZE}
					{filters}
					{refreshing}
					{selected}
					{grants}
					{grantsMeta}
					{references}
					{referencesMeta}
					{detailLoading}
					{detailError}
					{busyGrantId}
					{canRevoke}
					{canPurge}
					{purging}
					{driver}
					onOpenReference={(e) => api.openReference(e)}
					onFilterChange={(next) => {
						filters = next;
						page = 1;
					}}
					onPageChange={(p) => (page = p)}
					onRefresh={refresh}
					onSelect={select}
					onRevoke={handleRevoke}
					onPurge={handlePurge}
				/>
			{/snippet}
		</QuickViewHost>
	{/if}
</div>

<style>
	.page {
		padding: 28px 32px 48px;
		max-width: 1440px;
		margin: 0 auto;
	}

	.state {
		padding: 24px;
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		background: var(--surface);
	}

	.state p {
		margin: 0;
		font-size: 13px;
		color: var(--text-2);
	}

	.state-error p {
		color: var(--danger);
	}

	.retry-btn {
		margin-top: 12px;
		padding: 6px 14px;
		border: 1px solid var(--border-strong);
		border-radius: var(--r);
		background: var(--surface);
		color: var(--text);
		font-size: 12.5px;
		font-weight: 600;
		cursor: pointer;
	}

	.retry-btn:hover {
		background: var(--sunken);
	}
</style>
