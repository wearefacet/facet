<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { invalidateAll } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import History from '$lib/components/features/audit/History.svelte';
	import DoctypeHeader from '$lib/components/primitives/content/DoctypeHeader.svelte';
	import type { MutationRecord } from '$lib/datasource/types.js';
	import { setSearchParams } from '$lib/utils/searchParams.js';
	import * as m from '$lib/paraglide/messages';

	let { data } = $props();

	const def = $derived(data.def);
	const qualifiedName = $derived(data.qualifiedName as string);
	const docId = $derived(data.docId as string);
	const driver = $derived(data.driver);

	// `DocumentRef` for the loaded document — History calls `history()` and
	// `rollback()` on it. Rebuilt when the route params change.
	const documentRef = $derived(driver.domain(def.domain).doctype(def.doctype).doc(docId));

	const showHref = $derived(
		resolve('/[domain=notApi]/[doctype]/[id]', {
			domain: encodeURIComponent(def.domain),
			doctype: encodeURIComponent(def.doctype),
			id: encodeURIComponent(docId)
		})
	);

	const title = $derived(data.displayName ?? docId);

	// The inspected mutation rides the URL as `?mutation=<ulid>`: opening a
	// shared link selects that mutation directly, and every selection updates
	// the address bar (replaceState — no history pollution), so the link a
	// colleague receives targets the exact mutation on screen.
	const selectedMutationId = $derived(page.url.searchParams.get('mutation') ?? undefined);

	function handleSelect(mutation: MutationRecord | null): void {
		setSearchParams({ mutation: mutation?.id ?? null });
	}

	// Re-run the load (re-fetch doc display_name + version) after a successful
	// rollback so the header reflects the latest snapshot.
	async function handleRevert(): Promise<void> {
		await invalidateAll();
	}
</script>

<svelte:head>
	<title>{m.doc_history_page_title({ name: title, domain: def.domain })}</title>
</svelte:head>

<div class="history-page">
	<DoctypeHeader
		{title}
		color={def.color}
		backHref={showHref}
		backLabel={m.doc_back_to_document()}
		version={data.version}
		{qualifiedName}
	/>

	<div class="history-body">
		<History
			{documentRef}
			{driver}
			parentDocType={def.doctype}
			documentLabel={data.displayName ?? null}
			includeChildren
			selected={selectedMutationId}
			onSelect={handleSelect}
			onRevert={handleRevert}
		/>
	</div>
</div>

<style>
	.history-page {
		position: relative;
		height: 100%;
		min-height: 0;
		display: flex;
		flex-direction: column;
	}

	.history-body {
		flex: 1;
		min-height: 0;
		overflow: auto;
		padding: 24px;
		display: flex;
	}

	/* History fills the available width up to a readable max — matching the
	   stories' layout avoids the timeline being stretched edge-to-edge on
	   large monitors. */
	.history-body :global(.audit-trail) {
		width: 100%;
		max-width: 920px;
	}
</style>
