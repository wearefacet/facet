<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { invalidateAll } from '$app/navigation';
	import { DocumentDataSource } from '$lib/datasource/DocumentDataSource';
	import { toBannerError } from '$lib/datasource/bannerError.js';
	import { can } from '$lib/permissions.svelte';
	import type { AppContent, AppGrant, DoctypeCatalogueEntry } from '$lib/app/appTypes';
	import type { LayoutData } from '../$types';
	import AppGrantsEditor from '$lib/components/features/configure/AppGrantsEditor.svelte';
	import Button from '$lib/components/primitives/actions/Button.svelte';
	import AlertBanner from '$lib/components/primitives/content/AlertBanner.svelte';
	import * as m from '$lib/paraglide/messages';

	/**
	 * App detail Grants tab — renders the AppGrantsEditor in `edit` mode.
	 * The grants array is cloned into a local `$state` so the editor can
	 * mutate it freely (add/remove grants, flip `required`); changes are
	 * persisted on Save. The layout loaded the doctype catalogue, so the
	 * editor has everything it needs without another round-trip.
	 */

	let { data }: { data: LayoutData } = $props();

	let app = $derived(data.app.data);
	let meta = $derived(data.app.meta);
	let catalogue = $derived(data.catalogue as DoctypeCatalogueEntry[]);

	// Clone into a local $state so editor mutations don't dirty the
	// loaded document until Save. Guarded by a deep-equality check on the
	// source so a re-render of `app` with the same grants (e.g. an unrelated
	// invalidateAll) does not clobber the user's in-flight edits.
	let grants = $state<AppGrant[]>([]);
	let lastGrantsJson = '';
	$effect(() => {
		const source = app.grants ?? [];
		const json = JSON.stringify(source);
		if (json !== lastGrantsJson) {
			lastGrantsJson = json;
			grants = JSON.parse(json) as AppGrant[];
		}
	});

	let error = $state<string | undefined>(undefined);
	let errorDetails = $state<string[]>([]);
	let busy = $state(false);
	let dirty = $state(false);

	function onChange(next: AppGrant[]): void {
		dirty = true;
		void next;
	}

	async function save(): Promise<void> {
		busy = true;
		error = undefined;
		errorDetails = [];
		try {
			const apps = new DocumentDataSource<AppContent>('app', 'App');
			await apps.doc(meta.id).update({ grants });
			dirty = false;
			await invalidateAll();
		} catch (err) {
			const banner = toBannerError(err);
			error = banner.message;
			errorDetails = banner.details;
		} finally {
			busy = false;
		}
	}
</script>

<svelte:head>
	<title>{m.configure_apps_grants_page_title({ name: app.name })}</title>
</svelte:head>

<div class="grants-tab">
	{#if error}
		<AlertBanner
			message={error}
			details={errorDetails}
			dismissable
			onDismiss={() => (error = undefined)}
		/>
	{/if}

	<AppGrantsEditor bind:grants doctypeCatalogue={catalogue} mode="edit" onchange={onChange} />

	<div class="actions">
		<Button variant="primary" disabled={!dirty || busy || !can('app.App', 'update')} onclick={save}>
			{busy ? m.common_saving() : m.configure_apps_save_grants()}
		</Button>
	</div>
</div>

<style>
	.grants-tab {
		display: flex;
		flex-direction: column;
		gap: 16px;
	}

	.actions {
		display: flex;
		justify-content: flex-end;
	}
</style>
