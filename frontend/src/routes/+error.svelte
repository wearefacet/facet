<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { resolve } from '$app/paths';
	import { page } from '$app/state';
	import NotFoundPage from '$lib/components/primitives/surfaces/NotFoundPage.svelte';
	import { documentHistoryParams, errorPageKind } from '$lib/errorPage.js';

	interface ErrorWithStatus extends Error {
		status?: number;
	}

	const err = $derived(page.error as ErrorWithStatus | undefined);
	// The kind comes from structured data: SvelteKit tracks the failing HTTP
	// status in `page.status` (SSR response, hydration, client navigations),
	// while `page.error` is only the `App.Error` body and carries no status.
	// Message text is a last resort for errors with no status at all.
	const kind = $derived(
		errorPageKind({
			errorStatus: err?.status,
			pageStatus: page.status,
			message: err?.message
		})
	);

	// A deleted document keeps its readable audit trail, so the deleted page
	// offers the History shortcut. The router preserves route id + params when
	// a load error renders this page; params are raw (still-encoded) segments,
	// which is exactly what `resolve()` substitutes. Outside the document show
	// and edit routes — or when the router lost the route context — the button
	// stays hidden.
	const historyHref = $derived.by(() => {
		if (kind !== '410') return undefined;
		const doc = documentHistoryParams(page.route.id, page.params);
		return doc ? resolve('/[domain=notApi]/[doctype]/[id]/history', doc) : undefined;
	});
</script>

<svelte:head>
	<title>{m.errors_page_title()}</title>
</svelte:head>

<NotFoundPage status={kind} deleted={kind === '410'} message={err?.message} {historyHref} />

<style>
	:global(body) {
		margin: 0;
	}

	:global(:root) {
		height: 100%;
	}
</style>
