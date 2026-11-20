<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import DomainEditor from '$lib/components/features/configure/DomainEditor.svelte';
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { getDomainLabel } from '$lib/navState.svelte';
	import type { LayoutProps } from './$types';

	let { data }: LayoutProps = $props();

	const domainLabel = $derived(getDomainLabel(data.draftDomain));

	function handleDoctypeClick(qualified: string) {
		const dot = qualified.indexOf('.');
		goto(
			resolve('/Builder/[draftDomain]/[doctype]/[[tab]]', {
				draftDomain: qualified.slice(0, dot),
				doctype: qualified.slice(dot + 1),
				tab: 'fields'
			})
		);
	}
</script>

<!--
	The DomainEditor is rendered once here so a single instance persists across
	overview/doctypes/editors/grants tab navigations. The child +page.svelte files
	are intentionally empty (the route must exist to resolve the URL, but all
	markup lives here). Swapping tabs updates `data.tab` reactively — no remount,
	no domain-doc re-fetch, no flicker.
-->
<DomainEditor
	registry={data.registry}
	domain={data.draftDomain}
	tab={data.tab}
	ondoctypeclick={handleDoctypeClick}
/>

<svelte:head>
	<title>{m.builder_named_page_title({ name: domainLabel })}</title>
</svelte:head>
