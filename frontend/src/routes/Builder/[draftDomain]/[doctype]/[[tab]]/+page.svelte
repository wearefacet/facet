<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { page } from '$app/state';
	import DoctypeEditor from '$lib/components/features/configure/DoctypeEditor.svelte';

	let { data } = $props();

	const tab = $derived(
		page.params.tab as 'general' | 'fields' | 'children' | 'actions' | 'logic' | 'views' | undefined
	);
	const selectedFieldKey = $derived(page.url.searchParams.get('field') ?? undefined);
	const selectedViewKey = $derived(page.url.searchParams.get('view') ?? undefined);

	const doctypeLabel = $derived(
		data.def?.label?.trim() || data.qualifiedName.split('.').pop() || data.qualifiedName
	);
</script>

<svelte:head>
	<title>{m.builder_named_page_title({ name: doctypeLabel })}</title>
</svelte:head>

<DoctypeEditor
	registry={data.registry}
	qualifiedName={data.qualifiedName}
	{tab}
	{selectedFieldKey}
	{selectedViewKey}
	views={data.views}
	viewIds={data.viewIds}
/>
