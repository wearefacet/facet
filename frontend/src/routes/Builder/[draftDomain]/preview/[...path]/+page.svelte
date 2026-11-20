<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { onMount } from 'svelte';
	import { page } from '$app/state';
	import { startPreview } from '$lib/builderDraft.svelte';

	/**
	 * Builder preview wildcard — `/Builder/[draftDomain]/preview/[...path]`.
	 *
	 * This page is the entry point that swaps the brief from the Builder shell
	 * to the live application scoped to a draft dataset. It issues a preview
	 * capability token via `POST /Api/core/Domain/:id/preview-session` (the
	 * user's real cookie session still authorises the issuance because they
	 * are on a `/Builder` route), stages the result in the `previewSession`
	 * store so `apiFetch` overlays the Bearer header on every subsequent
	 * request, mirrors it into the `facet.preview-session` cookie so a full
	 * reload of `/_abc` survives F5, then performs a client-side navigation to
	 * `/${draftDomain}`.
	 *
	 * Once the navigation lands, the live `[domain=notApi]` page tree renders
	 * the draft's dashboard against draft data, authorised by
	 * `RBAC::PreviewEnforcer`. The bound draft stays visible in the sidebar via
	 * the preview carve-out in `buildNavModel` (which bypasses the `drafts:
	 * false` filter for `getPreviewSession().draftId`), and the
	 * `[domain=notApi]/+page.ts` load falls back to a direct `core.Domain`
	 * fetch for `_`-prefixed domain params during preview so the dashboard
	 * resolves the domain even before the parent layout's nav model is
	 * rebuilt client-side.
	 *
	 * If the user captured a `path` wildcard (e.g. a shared
	 * `/Builder/_abc/preview/_abc/Widget/01J...` link), the captured segments
	 * are forwarded through the `goto` so the deep-link lands on the same
	 * live document.
	 */
	onMount(() => {
		// The page load is path-stable, so `page.params.path` holds the
		// remaining segments after `/Builder/[draftDomain]/preview/`.
		const draftDomain = page.params.draftDomain;
		const path = page.params.path;
		if (!draftDomain) return;

		// `startPreview` reads the current draft state from `builderDraft.svelte`
		// — which is populated by the `(editor)/+layout.svelte` when the user
		// entered the builder subtree. If they deep-link here directly, the
		// builder store may be empty; in that case the issuance call still
		// targets `draftDomain` (the URL param), and the store is primed after.
		// `startPreview` rejects with an error message if no snapshot.id is set.
		startPreview(draftDomain).then((err: string | null) => {
			if (err) {
				// Issuance failed (403/404/422) — drop back to the builder
				// editor for the same draft so the user sees why preview could
				// not start.
				window.location.href = `/Builder/${draftDomain}/overview`;
				return;
			}
			// `startPreview` already navigated to `/_abc`; honour the captured
			// `path` if it extends the live URL (e.g. `_abc/Widget/01J...`).
			if (path) {
				import('$app/navigation').then(({ goto }) => goto(`/${path}`));
			}
		});
	});
</script>

<div class="starting">
	<p>{m.builder_preview_starting()}</p>
</div>

<style>
	.starting {
		display: grid;
		place-items: center;
		height: 100%;
		min-height: 40vh;
		padding: 32px;
		color: var(--text-2);
		font-size: 13px;
	}
</style>
