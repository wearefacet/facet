<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { goto, invalidateAll } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { DocumentDataSource } from '$lib/datasource/DocumentDataSource';
	import { toBannerError } from '$lib/datasource/bannerError.js';
	import type { AppContent } from '$lib/app/appTypes';
	import type { DocumentMeta } from '$lib/datasource/types';
	import { onPermissionRefresh } from '$lib/authorization/permissionRefresh.svelte.js';
	import { Plus, Trash2, Power, PowerOff, RotateCcw, Pencil, Globe, Server } from '@lucide/svelte';
	import Button from '$lib/components/primitives/actions/Button.svelte';
	import PageHeader from '$lib/components/primitives/surfaces/PageHeader.svelte';
	import RowList from '$lib/components/primitives/data/RowList.svelte';
	import RowItem from '$lib/components/primitives/data/RowItem.svelte';
	import AlertBanner from '$lib/components/primitives/content/AlertBanner.svelte';
	import Can from '$lib/components/primitives/surfaces/Can.svelte';
	import * as m from '$lib/paraglide/messages';

	/**
	 * Apps list — one row per `app.App` document. Drafts, active, and
	 * disabled apps share the same row collection because a draft is a
	 * state of the same object, not a separate collection. Row actions
	 * follow the lifecycle: open detail (primary), and the status
	 * transition / discard affordance as the secondary action.
	 */

	let {
		data
	}: {
		data: { apps: { data: AppContent; meta: DocumentMeta }[]; revisions: Map<string, number> };
	} = $props();

	type Row = { app: AppContent; meta: DocumentMeta };
	const rows = $derived<Row[]>(
		[...data.apps]
			// Drafts first (in-progress work), then by status, then by display name.
			.sort((a, b) => {
				const rank = (s?: string) => (s === 'draft' ? 0 : s === 'active' ? 1 : 2);
				const d = rank(a.data.status) - rank(b.data.status);
				if (d !== 0) return d;
				return (a.data.name ?? '').localeCompare(b.data.name ?? '');
			})
			.map((item) => ({ app: item.data, meta: item.meta }))
	);

	let error = $state<string | undefined>(undefined);
	let errorDetails = $state<string[]>([]);
	let busyId = $state<string | undefined>(undefined);

	// Mutation helper. Routes through the DataSource (uses apiFetch, so
	// token refresh stays active) and invalidates the show cache so the
	// next read observes the post-action state.
	async function setStatus(meta: DocumentMeta, status: 'active' | 'disabled'): Promise<void> {
		busyId = meta.id;
		try {
			const apps = new DocumentDataSource<AppContent>('app', 'App');
			await apps.doc(meta.id).update({ status });
			await invalidateAll();
		} catch (err) {
			const banner = toBannerError(err);
			error = banner.message;
			errorDetails = banner.details;
		} finally {
			busyId = undefined;
		}
	}

	async function discard(meta: DocumentMeta): Promise<void> {
		if (!confirm(m.configure_apps_discard_confirm({ name: meta.id }))) return;
		busyId = meta.id;
		try {
			const apps = new DocumentDataSource<AppContent>('app', 'App');
			await apps.doc(meta.id).delete();
			await invalidateAll();
		} catch (err) {
			const banner = toBannerError(err);
			error = banner.message;
			errorDetails = banner.details;
		} finally {
			busyId = undefined;
		}
	}

	// Re-render on permission refresh so the gating re-evaluates when the
	// active role changes. Mirrors the domains list's pattern.
	onPermissionRefresh(() => invalidateAll());
</script>

<svelte:head>
	<title>{m.configure_apps_page_title()}</title>
</svelte:head>

<div class="page">
	<PageHeader title={m.configure_apps_title()} subtitle={m.configure_apps_subtitle()}>
		{#snippet actions()}
			<Can doctype="app.App" action="create">
				<Button variant="primary" onclick={() => goto(resolve('/Configure/apps/new/setup'))}>
					{#snippet iconLeft()}
						<Plus size={14} strokeWidth={2} aria-hidden="true" />
					{/snippet}
					{m.configure_apps_new_button()}
				</Button>
			</Can>
		{/snippet}
	</PageHeader>

	{#if rows.length === 0}
		<div class="empty">
			<div class="empty-head">
				<div class="empty-title">{m.configure_apps_empty_title()}</div>
				<div class="empty-sub">
					{m.configure_apps_empty_sub()}
				</div>
			</div>

			<div class="presets">
				<button
					type="button"
					class="preset"
					onclick={() => goto(resolve('/Configure/apps/new/setup?preset=external'))}
				>
					<Globe size={20} strokeWidth={1.9} class="preset-icon" aria-hidden="true" />
					<div class="preset-name">{m.configure_apps_preset_web_name()}</div>
					<div class="preset-desc">{m.configure_apps_preset_web_desc()}</div>
					<div class="preset-tag">{m.configure_apps_preset_web_tag()}</div>
				</button>

				<button
					type="button"
					class="preset"
					onclick={() => goto(resolve('/Configure/apps/new/setup?preset=backend'))}
				>
					<Server size={20} strokeWidth={1.9} class="preset-icon" aria-hidden="true" />
					<div class="preset-name">{m.configure_apps_preset_backend_name()}</div>
					<div class="preset-desc">
						{m.configure_apps_preset_backend_desc()}
					</div>
					<div class="preset-tag">{m.configure_apps_preset_backend_tag()}</div>
				</button>
			</div>
		</div>
	{:else}
		{#if error}
			<AlertBanner
				message={error}
				details={errorDetails}
				dismissable
				onDismiss={() => (error = undefined)}
			/>
		{/if}

		<RowList>
			{#each rows as row (row.meta.id)}
				{@const a = row.app}
				{@const status = a.status ?? 'draft'}
				<RowItem state={status}>
					<div class="meta">
						<span class="name">{a.name}</span>
						<span class="sub">
							{#if status === 'draft'}
								{m.configure_apps_row_draft_grants({ count: (a.grants ?? []).length })}
							{:else}
								{m.configure_apps_row_grants({
									count: (a.grants ?? []).length,
									type: a.client_type ?? 'public'
								})}
							{/if}
						</span>
					</div>
					<span class="badge" data-state={status}>{status}</span>
					{#if data.revisions.get(row.meta.id)}
						<span class="rev-badge" title={m.configure_apps_rev_title()}>
							r{data.revisions.get(row.meta.id)}</span
						>
					{/if}
					<div class="actions">
						<Button
							variant="ghost"
							size="sm"
							onclick={() => goto(resolve('/Configure/apps/[slug]', { slug: a.slug }))}
						>
							{#snippet iconLeft()}
								<Pencil size={13} strokeWidth={2} aria-hidden="true" />
							{/snippet}
							{m.configure_apps_open()}
						</Button>
						{#if status === 'draft'}
							<Can doctype="app.App" action="update">
								<Button
									variant="ghost"
									size="sm"
									title={m.configure_apps_activate_title()}
									disabled={busyId === row.meta.id}
									onclick={() => setStatus(row.meta, 'active')}
								>
									{#snippet iconLeft()}
										<Power size={13} strokeWidth={2} aria-hidden="true" />
									{/snippet}
									{m.configure_apps_activate()}
								</Button>
							</Can>
							<Can doctype="app.App" action="delete">
								<Button
									variant="ghost"
									size="sm"
									title={m.configure_apps_discard_title()}
									disabled={busyId === row.meta.id}
									onclick={() => discard(row.meta)}
								>
									{#snippet iconLeft()}
										<Trash2 size={13} strokeWidth={2} aria-hidden="true" />
									{/snippet}
								</Button>
							</Can>
						{:else if status === 'active'}
							<Can doctype="app.App" action="update">
								<Button
									variant="ghost"
									size="sm"
									title={m.configure_apps_disable_title()}
									disabled={busyId === row.meta.id}
									onclick={() => setStatus(row.meta, 'disabled')}
								>
									{#snippet iconLeft()}
										<PowerOff size={13} strokeWidth={2} aria-hidden="true" />
									{/snippet}
									{m.configure_apps_disable()}
								</Button>
							</Can>
						{:else}
							<Can doctype="app.App" action="update">
								<Button
									variant="ghost"
									size="sm"
									title={m.configure_apps_reenable_title()}
									disabled={busyId === row.meta.id}
									onclick={() => setStatus(row.meta, 'active')}
								>
									{#snippet iconLeft()}
										<RotateCcw size={13} strokeWidth={2} aria-hidden="true" />
									{/snippet}
									{m.configure_apps_reenable()}
								</Button>
							</Can>
						{/if}
					</div>
				</RowItem>
			{/each}
		</RowList>
	{/if}
</div>

<style>
	.page {
		padding: 28px 32px 48px;
		max-width: 960px;
		margin: 0 auto;
	}

	.meta {
		display: flex;
		flex-direction: column;
		gap: 2px;
		min-width: 0;
		flex: 1;
	}

	.name {
		font-size: 14px;
		font-weight: 600;
		color: var(--text);
	}

	.sub {
		font-size: 11.5px;
		color: var(--text-3);
		font-family: var(--font-mono);
	}

	.badge {
		margin-left: auto;
		padding: 2px 9px;
		border-radius: var(--r-pill, 999px);
		font-family: var(--font-mono);
		font-size: 10.5px;
		font-weight: 600;
		text-transform: lowercase;
		flex: none;
		background: color-mix(in srgb, var(--badge-color) 12%, transparent);
		color: var(--badge-color);
	}

	.badge[data-state='draft'] {
		--badge-color: var(--warn, #d97706);
	}

	.badge[data-state='active'] {
		--badge-color: var(--ok, #16a34a);
	}

	.badge[data-state='disabled'] {
		--badge-color: var(--text-3);
	}

	.rev-badge {
		flex: none;
		padding: 2px 9px;
		border-radius: var(--r-pill, 999px);
		font-family: var(--font-mono);
		font-size: 10.5px;
		font-weight: 600;
		background: var(--accent-weak);
		color: var(--accent-ink);
	}

	.actions {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		flex: none;
	}

	/* ── Empty state with presets ────────────────────────────────────────── */

	.empty {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 1.25rem;
		padding: 0 0 1.25rem;
		text-align: center;
	}

	.empty-head {
		display: flex;
		flex-direction: column;
		align-items: center;
		gap: 6px;
	}

	.empty-title {
		font-size: 18px;
		font-weight: 500;
		color: var(--text);
	}

	.empty-sub {
		color: var(--text-3);
		font-size: 13.5px;
		max-width: 420px;
		line-height: 1.6;
	}

	.presets {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(170px, 1fr));
		gap: 12px;
		width: 100%;
		max-width: 640px;
	}

	.preset {
		display: flex;
		flex-direction: column;
		align-items: flex-start;
		gap: 4px;
		padding: 14px;
		background: var(--surface-2);
		border: 0.5px solid var(--border);
		border-radius: var(--r-lg, 12px);
		text-align: left;
		cursor: pointer;
		font: inherit;
		color: var(--text);
		transition:
			border-color 0.12s,
			background 0.12s;
	}

	.preset:hover:not(:disabled) {
		border-color: var(--accent);
		background: var(--accent-weak);
	}

	:global(.preset-icon) {
		color: var(--accent);
	}

	.preset-name {
		font-size: 14px;
		font-weight: 500;
		margin-top: 8px;
		color: var(--text);
	}

	.preset-desc {
		font-size: 12.5px;
		color: var(--text-3);
		margin-top: 4px;
		line-height: 1.55;
	}

	.preset-tag {
		font-size: 11.5px;
		color: var(--text-3);
		margin-top: 10px;
		font-family: var(--font-mono);
	}
</style>
