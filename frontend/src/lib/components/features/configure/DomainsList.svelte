<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { page } from '$app/state';

	import RelativeTime from '../../primitives/data/RelativeTime.svelte';
	import Button from '../../primitives/actions/Button.svelte';
	import DropdownMenu, { type MenuItem } from '../../primitives/actions/DropdownMenu.svelte';
	import Input from '../../primitives/forms/Input.svelte';
	import NewDomainDialog from '../dashboard/NewDomainDialog.svelte';
	import { flattenNavDoctypes, type NavDomain } from '$lib/navTypes';
	import { MoreVertical } from '@lucide/svelte';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import { domainListCache, doctypeRegistryCache } from '$lib/datasource/clientCache.js';
	import { buildNavModel, domainProjectionToNavDomain } from '$lib/navModel';
	import { getPermissions } from '$lib/permissions.svelte';
	import { errorMessage } from '$lib/datasource/bannerError.js';
	import { onPermissionRefresh } from '$lib/authorization/permissionRefresh.svelte.js';
	import { apiFetch } from '$lib/session.svelte';
	import {
		enqueueDomainExport,
		pollJob,
		domainDownloadUrl,
		PortableDomainError,
		type FetchImpl
	} from '$lib/portableDomains/portableDomainsClient.js';
	import { isSystemDomain } from '$lib/systemDomains.js';
	import { toast } from '$lib/toast.svelte.js';
	import * as m from '$lib/paraglide/messages';

	/**
	 * DomainsList — the two-section list surface of the domains landing page:
	 * drafts (in-progress work, shown first) and published live domains
	 * (filter/searchable).
	 *
	 * The host page owns the published-domain data (layout load, passed as
	 * the `domains` prop), the import / delete dialogs, and navigation
	 * (passed as callbacks). This component owns the draft lifecycle — load,
	 * create empty, branch from published, discard — the export flow, and
	 * the row actions. The driver is injected, so stories can mount a mock
	 * driver.
	 */

	let {
		/** Published domains from the host's layout load. */
		domains,
		/** Driver for the client-side draft loads. Injectable so stories can mount a mock driver. */
		driver,
		/** Open the builder for a draft (host navigation). */
		onopenbuilder,
		/** Open a published domain's configure route (host navigation). */
		onconfigure,
		/** Delete a published domain. The host owns the confirm dialog. */
		ondelete,
		/** Two-way bound with the host: the page-header button opens the
		 * new-domain dialog this component renders. */
		newDialogOpen = $bindable(false),
		/** Report draft load / create / discard errors. The host renders them
		 * in its alert banner, above its explain band. */
		ondrafterror
	}: {
		domains: NavDomain[];
		driver: DataDriver;
		onopenbuilder: (draftId: string) => void;
		onconfigure: (slug: string) => void;
		ondelete: (domain: NavDomain) => void;
		newDialogOpen?: boolean;
		ondrafterror?: (message: string | undefined) => void;
	} = $props();

	// apiFetch typed down to the client's FetchImpl seam (token refresh and
	// 401 recovery stay in the loop — same cast the impex components use).
	const fetchImpl = apiFetch as unknown as FetchImpl;

	// Drafts are fetched client-side on mount (matching the root layout's
	// builder-mode pattern). Published domains come from the host.
	let drafts = $state<NavDomain[]>([]);

	async function loadDrafts() {
		try {
			const permissions = getPermissions() ?? undefined;
			const model = await buildNavModel(driver, permissions, { drafts: true });
			drafts = model;
			ondrafterror?.(undefined);
		} catch (err) {
			ondrafterror?.(errorMessage(err));
		}
	}

	$effect(() => {
		void page.url.pathname; // reload drafts when re-entering the configure subtree
		loadDrafts();
	});

	// ── Draft lifecycle ──────────────────────────────────────────────────────

	async function newDraftFromPublished(sourceId: string) {
		// Drafts a clone of the published domain. Mirrors the root layout's
		// handleEditDomain. Returns to the configure list on success (the
		// draft appears at the top), surfaces the error inline on failure.
		try {
			const res = await apiFetch(`/Api/core/Domain/${sourceId}/draft`, {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: '{}'
			});
			if (!res.ok) {
				const body = await res.json().catch(() => ({}));
				ondrafterror?.(body.error ?? m.builder_draft_failed_status({ status: res.status }));
				return;
			}
			const newDraft = await res.json();
			// Prepend the new draft and refresh the registry's view of it.
			const nav = domainProjectionToNavDomain(newDraft);
			drafts = [nav, ...drafts.filter((d) => d.id !== nav.id)];
			// Drop the cached pre-creation snapshots so loadDrafts sees the new
			// draft instead of overwriting the prepend with a stale 60s-TTL
			// entry, and the next /Builder entry fetches the copied doctypes.
			domainListCache.invalidate();
			doctypeRegistryCache.invalidate();
			loadDrafts(); // refresh the full draft list (doctype count, meta)
		} catch {
			ondrafterror?.(m.builder_draft_network_error());
		}
	}

	// Creates a new empty draft with a user-chosen id and label. Called by the
	// NewDomainDialog; returns null on success (the dialog closes) or an
	// error message string (shown inline) matching the dialog's contract.
	async function newEmptyDraft(input: { name: string; label?: string }): Promise<string | null> {
		let res: Response;
		try {
			res = await apiFetch('/Api/core/Domain/draft', {
				method: 'POST',
				headers: { 'Content-Type': 'application/json' },
				body: JSON.stringify({ name: input.name, label: input.label || undefined })
			});
		} catch {
			return m.builder_draft_network_error();
		}
		if (!res.ok) {
			const body = await res.json().catch(() => ({}));
			return body.error ?? m.builder_draft_failed_status({ status: res.status });
		}
		const newDraft = await res.json();
		// Prepend the new draft and refresh the registry's view of it.
		const nav = domainProjectionToNavDomain(newDraft);
		drafts = [nav, ...drafts.filter((d) => d.id !== nav.id)];
		// Drop the cached pre-creation domain list so loadDrafts sees the new
		// draft instead of overwriting the prepend with a stale 60s-TTL entry.
		domainListCache.invalidate();
		loadDrafts(); // refresh the full draft list (doctype count, meta)
		return null;
	}

	// Discard is a destructive action. It lives in the row overflow menu.
	// We use a confirm() gateway until a proper dialog matches the rest of
	// the app's patterns.
	//
	// Discard goes through `POST /Api/core/Domain/:id/drop` — the same
	// endpoint as published-domain deletion. The generic document
	// `DELETE /Api/core/Domain/:id` is refused server-side (a lone Domain
	// tombstone would orphan the draft's definitions and data).
	async function discardDraft(draftId: string) {
		if (!confirm(m.configure_domains_draft_confirm({ name: draftId }))) return;
		try {
			const res = await apiFetch(`/Api/core/Domain/${draftId}/drop`, { method: 'POST' });
			if (!res.ok) {
				const body = await res.json().catch(() => ({}));
				ondrafterror?.(body.error ?? m.builder_draft_failed_status({ status: res.status }));
				return;
			}
			drafts = drafts.filter((d) => d.id !== draftId);
			// Drop the cached list that still holds the discarded draft, so a
			// rebuild does not resurrect it in the sidebar within the TTL.
			domainListCache.invalidate();
		} catch {
			ondrafterror?.(m.configure_domains_network_discard_error());
		}
	}

	// ── Export ───────────────────────────────────────────────────────────

	// The published domain an export job is enqueuing for (disables the
	// menu item until the enqueue resolves — the poll runs detached).
	let exportingId = $state<string | undefined>(undefined);

	// Exports one published domain as a portable bundle. The job enqueues
	// here and polls detached — a completion toast carries the download
	// link (the backend's notification is the durable surface). A draft
	// refuses server-side, so the menu item is published-rows only.
	async function exportDomain(domainId: string) {
		if (exportingId) return;
		exportingId = domainId;
		try {
			const enqueued = await enqueueDomainExport(fetchImpl, domainId);
			toast({ message: m.impex_export_started() });

			void pollJob(fetchImpl, enqueued.jobId).then((outcome) => {
				if (outcome.mode === 'timeout') return;
				if (outcome.status.status === 'succeeded') {
					toast({
						message: m.impex_export_ready(),
						variant: 'ok',
						action: {
							label: m.impex_download(),
							href: domainDownloadUrl(enqueued.jobId)
						}
					});
				} else {
					// The backend's rejection (version gate, vanished role, …)
					// rides the failed outcome — surface it verbatim.
					toast({
						message: outcome.status.error ?? m.impex_export_failed(),
						variant: 'error'
					});
				}
			});
		} catch (e) {
			toast({
				message: e instanceof PortableDomainError ? e.message : m.impex_export_start_failed(),
				variant: 'error'
			});
		} finally {
			exportingId = undefined;
		}
	}

	// ── Row actions ──────────────────────────────────────────────────────

	function draftMenu(d: NavDomain): MenuItem[] {
		return [
			{
				label: m.configure_domains_discard_title(),
				variant: 'danger',
				onclick: () => discardDraft(d.id)
			}
		];
	}

	function publishedMenu(d: NavDomain): MenuItem[] {
		// System domains (core, iam, app) cannot be deleted — the backend
		// refuses the drop — so the menu item is not offered for them.
		const items: MenuItem[] = [
			{ label: m.configure_domains_new_draft_item(), onclick: () => newDraftFromPublished(d.id) },
			{
				label: m.configure_domains_export_item(),
				disabled: exportingId !== undefined,
				onclick: () => exportDomain(d.id)
			}
		];
		if (!isSystemDomain(d.id)) {
			items.push({
				label: m.configure_domains_delete_button(),
				variant: 'danger',
				onclick: () => ondelete(d)
			});
		}
		return items;
	}

	// Reload the draft list on the permission-refresh signal. The host page
	// re-runs its own loads on the same signal.
	onPermissionRefresh(() => {
		void loadDrafts();
	});

	// ── Published filter (view-side; the host owns the unfiltered list) ──
	let publishedFilter = $state('');

	const published = $derived(
		publishedFilter
			? domains.filter((d) => {
					const q = publishedFilter.toLowerCase();
					return d.label.toLowerCase().includes(q);
				})
			: domains
	);
</script>

<section class="group">
	<header class="group-head">
		<h3>{m.configure_domains_drafts_title()}</h3>
		<span class="group-count"
			>{m.configure_domains_in_progress_count({ count: drafts.length })}</span
		>
	</header>

	{#if drafts.length > 0}
		<ul class="draft-list">
			{#each drafts as d (d.id)}
				<li class="draft-row">
					<div class="row-main">
						<div class="row-title">
							<span class="row-name">{d.label}</span>
							<span class="draft-badge">{m.configure_domains_draft_tag()}</span>
						</div>
						<p class="row-sub">
							{m.configure_domains_last_edited()}
							{#if d.updatedAt}
								<RelativeTime date={d.updatedAt} />
							{:else}
								{m.configure_domains_just_now()}
							{/if}
						</p>
					</div>
					<div class="row-actions">
						<Button variant="primary" size="sm" onclick={() => onopenbuilder(d.id)}
							>{m.configure_domains_open_editor()}</Button
						>
						<Button variant="secondary" size="sm" onclick={() => onopenbuilder(d.id)}
							>{m.configure_domains_review_changes()}</Button
						>
						<DropdownMenu
							label={m.configure_options_aria()}
							items={draftMenu(d)}
							align="end"
							trigger="icon"
						>
							<MoreVertical size={15} strokeWidth={2} aria-hidden="true" />
						</DropdownMenu>
					</div>
				</li>
			{/each}
		</ul>
	{:else}
		<p class="empty-note">{m.configure_domains_drafts_empty()}</p>
	{/if}
</section>

<div class="group-head published">
	<h3>{m.configure_domains_published_title()}</h3>
	<span class="group-count">{m.configure_domains_live_count({ count: domains.length })}</span>
	<div class="filter">
		<Input
			type="text"
			bind:value={publishedFilter}
			placeholder={m.configure_domains_filter_placeholder()}
		/>
	</div>
</div>

{#if published.length > 0}
	<ul class="publish-list">
		{#each published as d (d.id)}
			<li class="publish-row">
				<span class="dot" style={`background:${d.color ?? 'var(--text-3)'}`} aria-hidden="true"
				></span>
				<div class="row-main">
					<p class="row-name row-name-lg">{d.label}</p>
					<p class="row-sub">
						{m.configure_domains_doctypes_short({
							count: flattenNavDoctypes(d.doctypes).length
						})}
					</p>
				</div>
				<div class="row-actions">
					<Button variant="secondary" size="sm" onclick={() => onconfigure(d.id)}
						>{m.nav_configure()}</Button
					>
					<DropdownMenu
						label={m.configure_options_aria()}
						items={publishedMenu(d)}
						align="end"
						trigger="icon"
					>
						<MoreVertical size={13} strokeWidth={2} aria-hidden="true" />
					</DropdownMenu>
				</div>
			</li>
		{/each}
	</ul>
{:else}
	<p class="empty">
		{m.configure_domains_empty()}
	</p>
{/if}

<NewDomainDialog bind:open={newDialogOpen} oncreate={newEmptyDraft} />

<style>
	/* ── Section headers ─────────────────────────────────────────────────── */
	.group-head {
		display: flex;
		align-items: center;
		gap: 8px;
	}

	.group-head.published {
		margin-bottom: 10px;
	}

	.group-head h3 {
		margin: 0;
		font-size: 14px;
		font-weight: 500;
		color: var(--text);
	}

	.group-count {
		font-size: 12px;
		color: var(--text-3);
	}

	.filter {
		margin-left: auto;
		width: 200px;
	}

	.filter :global(.input-field) {
		height: 30px;
		padding-block: 0;
	}

	/* ── Draft rows ──────────────────────────────────────────────────────── */
	.draft-list {
		list-style: none;
		margin: 0 0 26px;
		padding: 0;
		display: flex;
		flex-direction: column;
		gap: 6px;
	}

	.draft-row {
		display: flex;
		align-items: center;
		gap: 12px;
		padding: 13px 16px;
		border: 1px solid var(--accent);
		border-radius: var(--r-lg);
		background: var(--accent-weak);
	}

	/* ── Published rows ──────────────────────────────────────────────────── */
	.publish-list {
		list-style: none;
		margin: 0;
		padding: 0;
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		overflow: hidden;
		background: var(--surface);
	}

	.publish-row {
		display: flex;
		align-items: center;
		gap: 12px;
		padding: 13px 16px;
		border-bottom: 1px solid var(--border);
	}

	.publish-row:last-child {
		border-bottom: none;
	}

	.dot {
		width: 9px;
		height: 9px;
		border-radius: 2px;
		transform: rotate(45deg);
		flex: none;
	}

	/* ── Shared row bits ─────────────────────────────────────────────────── */
	.row-main {
		flex: 1;
		min-width: 0;
		display: flex;
		flex-direction: column;
		gap: 2px;
	}

	.row-title {
		display: flex;
		align-items: center;
		gap: 8px;
		min-width: 0;
	}

	.row-name {
		font-size: 15px;
		font-weight: 500;
		color: var(--text);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.row-name-lg {
		font-size: 15px;
	}

	.row-sub {
		margin: 0;
		font-size: 12px;
		color: var(--text-3);
		font-family: var(--font-mono);
	}

	.draft-badge {
		flex: none;
		font-family: var(--font-mono);
		font-size: 11px;
		font-weight: 600;
		padding: 1px 7px;
		border-radius: var(--r-pill, 999px);
		background: var(--surface-2);
		color: var(--text-2);
	}

	.row-actions {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		flex: none;
	}

	.empty {
		font-size: 13.5px;
		color: var(--text-3);
		line-height: 1.5;
	}
</style>
