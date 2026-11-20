<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { resolve } from '$app/paths';
	import type { LayoutData } from './$types';
	import PageHeader from '$lib/components/primitives/surfaces/PageHeader.svelte';
	import * as m from '$lib/paraglide/messages';

	/**
	 * App detail shell — owns the title block and the Overview / Grants /
	 * Settings tab strip. The layout load resolves the app document once
	 * and threads it down via `data` so tab switches do not refetch
	 * (the `documentShowCache` TTL window and the load-derived data keep
	 * the active tab consistent without a network round-trip).
	 */

	let { data, children }: { data: LayoutData; children: import('svelte').Snippet } = $props();

	let { slug, tab } = $derived(data);
	let app = $derived(data.app);

	let status = $derived(app.data.status ?? 'draft');
</script>

<svelte:head>
	<title>{m.configure_apps_detail_page_title({ name: app.data.name })}</title>
</svelte:head>

<div class="page">
	<PageHeader title={app.data.name} subtitle={app.data.slug}>
		{#snippet actions()}
			<span class="badge" data-state={status}>{status}</span>
		{/snippet}
	</PageHeader>

	{#if status === 'draft'}
		<div class="resume-banner">
			{m.configure_apps_draft_banner()}
			<a href={resolve('/Configure/apps/new/setup')} class="resume-link"
				>{m.configure_apps_resume_link()}</a
			>
		</div>
	{/if}

	<div class="tabs">
		<a href={resolve('/Configure/apps/[slug]/overview', { slug })} class:on={tab === 'overview'}
			>{m.configure_domains_tab_overview()}</a
		>
		<a href={resolve('/Configure/apps/[slug]/grants', { slug })} class:on={tab === 'grants'}
			>{m.configure_domains_tab_grants()}</a
		>
		<a href={resolve('/Configure/apps/[slug]/settings', { slug })} class:on={tab === 'settings'}
			>{m.configure_doctypes_tab_settings()}</a
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

	.badge {
		padding: 2px 9px;
		border-radius: var(--r-pill, 999px);
		font-family: var(--font-mono);
		font-size: 10.5px;
		font-weight: 600;
		text-transform: lowercase;
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

	.resume-banner {
		display: flex;
		align-items: center;
		gap: 8px;
		flex-wrap: wrap;
		margin-bottom: 16px;
		padding: 9px 12px;
		font-size: 13px;
		color: var(--warn, #d97706);
		background: var(--warn-weak, rgba(217, 119, 6, 0.12));
		border: 1px solid var(--warn, #d97706);
		border-radius: var(--r);
	}

	.resume-link {
		margin-left: auto;
		color: inherit;
		font-weight: 600;
		text-decoration: none;
	}

	.resume-link:hover {
		text-decoration: underline;
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
