<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { resolve } from '$app/paths';
	import DoctypeEditor from '$lib/components/features/configure/DoctypeEditor.svelte';
	import { DocumentDataDriver } from '$lib/datasource/DocumentDriver';
	import { DoctypeRegistry } from '$lib/datasource/DoctypeRegistry.js';
	import { errorMessage } from '$lib/datasource/bannerError.js';
	import { can } from '$lib/permissions.svelte';
	import { loadDoctypeViewsWithIds } from '$lib/doctype/loadDocumentView.js';
	import type { ViewKind } from '$lib/doctype/previewDocument.js';
	import type { TemplateNode } from '$lib/template-types.js';
	import type { PageData } from './$types';
	import * as m from '$lib/paraglide/messages';

	/**
	 * Per-doctype published detail.
	 *
	 * Reuses DoctypeEditor (same as the builder's doctype editor) but in
	 * the configure shell. Shape-change controls (add/remove/rename field,
	 * type changes, references) render disabled with a `requires draft`
	 * pill that, on click, branches a draft and routes to the builder.
	 *
	 * Presentation metadata (label, plural label, icon, color, description)
	 * stays editable without a draft for roles holding `update
	 * core.DocType` (`allowMetadataEdit`): a metadata-only PUT on the live
	 * definition passes the backend's same-version guards, so the General
	 * tab saves in place.
	 *
	 * The defined `core.DocumentView` templates load read-only so the
	 * Views tab shows what is actually configured (the builder loads the
	 * same way); without them every kind would render a false `fallback`
	 * badge. Records open through the standard workspace surface.
	 */

	let { data }: { data: PageData } = $props();

	let registry = $state<Awaited<ReturnType<typeof DoctypeRegistry.cached>> | undefined>(undefined);
	let views = $state<Partial<Record<ViewKind, TemplateNode | null>>>({});
	let viewIds = $state<Partial<Record<ViewKind, string>>>({});
	let loadError = $state<string | undefined>(undefined);

	$effect(() => {
		void data.slug;
		void data.dt;
		const driver = new DocumentDataDriver('');
		DoctypeRegistry.cached(driver)
			.then((r) => {
				registry = r;
				loadError = undefined;
				// Fresh fetch: a cached list may be older than an external write
				// (a second tab, the assistant). This effect re-runs on route
				// entry and whenever the loads re-run (`invalidateAll()`), so
				// each run shows the templates as stored now.
				return loadDoctypeViewsWithIds(driver, qualified, { fresh: true });
			})
			.then((v) => {
				views = v.templates as Partial<Record<ViewKind, TemplateNode | null>>;
				viewIds = v.ids;
			})
			.catch((err) => {
				loadError = errorMessage(err);
			});
	});

	const qualified = $derived(`${data.slug}.${data.dt}`);
</script>

{#if loadError}
	<div class="err">{loadError}</div>
{:else if !registry}
	<div class="loading">{m.configure_doctypes_loading()}</div>
{:else}
	<DoctypeEditor
		{registry}
		qualifiedName={qualified}
		readonly={true}
		allowMetadataEdit={can('core.DocType', 'update')}
		{views}
		{viewIds}
		recordsHref={resolve('/[domain=notApi]/[doctype]', { domain: data.slug, doctype: data.dt })}
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
