<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import DomainEditor from '$lib/components/features/configure/DomainEditor.svelte';
	import { DocumentDataDriver } from '$lib/datasource/DocumentDriver';
	import { DoctypeRegistry } from '$lib/datasource/DoctypeRegistry.js';
	import { errorMessage } from '$lib/datasource/bannerError.js';
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import type { LayoutProps } from './$types';
	import * as m from '$lib/paraglide/messages';

	/**
	 * Published config detail — host of the four tab routes.
	 *
	 * A deeper +page.svelte replaces the parent page, so the four tab
	 * routes render through this layout: the DomainEditor mounts once and
	 * persists across tab switches (no remount, no domain-doc re-fetch).
	 * This mirrors the builder `(editor)/+layout.svelte` pattern; the
	 * `[slug]/+layout.ts` load derives `slug` and the active `tab` for the
	 * whole subtree.
	 *
	 * The per-doctype route (`doctypes/[dt]`) sits outside this group, so
	 * its standalone DoctypeEditor page never doubles with this editor.
	 */

	let { data }: LayoutProps = $props();

	// The doctype registry loads client-side, per detail — the same pattern
	// as the per-doctype page. The configure shell does not need the
	// registry for /access or /audit, so its own layout stays lean.
	let registry = $state<Awaited<ReturnType<typeof DoctypeRegistry.cached>> | undefined>(undefined);
	let loadError = $state<string | undefined>(undefined);

	$effect(() => {
		void data.slug;
		const driver = new DocumentDataDriver('');
		DoctypeRegistry.cached(driver)
			.then((r) => {
				registry = r;
				loadError = undefined;
			})
			.catch((err) => {
				loadError = errorMessage(err);
			});
	});

	function handleDoctypeClick(qualified: string) {
		// A doctype click opens its published per-doctype detail.
		const [domain, doctype] = qualified.split('.');
		goto(resolve('/Configure/domains/[slug]/doctypes/[dt]', { slug: domain, dt: doctype }));
	}

	function handleTabSelect(tab: 'overview' | 'doctypes' | 'editors' | 'grants' | 'check') {
		// The published detail hosts the four live tabs. `check` is
		// draft-only and has no route here, so it is ignored.
		if (tab === 'check') return;
		goto(resolve(`/Configure/domains/[slug]/(tabs)/${tab}`, { slug: data.slug }));
	}
</script>

<svelte:head>
	<title>{m.configure_domains_detail_page_title({ name: data.slug })}</title>
</svelte:head>

{#if loadError}
	<div class="err">{loadError}</div>
{:else if !registry}
	<div class="loading">{m.configure_domains_loading()}</div>
{:else}
	<DomainEditor
		{registry}
		domain={data.slug}
		tab={data.tab}
		ontabselect={handleTabSelect}
		ondoctypeclick={handleDoctypeClick}
		crumb={{ label: m.configure_domains_list_title(), href: resolve('/Configure/domains') }}
	/>
{/if}

<style>
	.err,
	.loading {
		padding: 24px 32px;
		font-size: 13px;
		color: var(--text-3);
	}

	.err {
		color: var(--danger, #c0392b);
	}
</style>
