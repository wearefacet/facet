<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { goto, invalidateAll } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { DocumentDataSource } from '$lib/datasource/DocumentDataSource';
	import { toBannerError } from '$lib/datasource/bannerError.js';
	import type { AppContent, DoctypeCatalogueEntry } from '$lib/app/appTypes';
	import type { LayoutData } from '../$types';
	import AlertBanner from '$lib/components/primitives/content/AlertBanner.svelte';
	import PermissionsForm from '$lib/components/features/apps/PermissionsForm.svelte';
	import * as m from '$lib/paraglide/messages';

	/**
	 * Wizard step 2 — permissions. A thin page: it wires the
	 * PermissionsForm component to the loaded draft and owns the save and
	 * the navigation. The grants draft, the service-role picker, and the
	 * step UI live in the component.
	 */

	let { data }: { data: LayoutData } = $props();

	let error = $state<string | undefined>(undefined);
	let errorDetails = $state<string[]>([]);
	let busy = $state(false);

	async function onBack(): Promise<void> {
		await goto(resolve(`/Configure/apps/new/setup?app=${data.app!.meta.id}`));
	}

	async function onContinue(payload: Partial<AppContent>): Promise<void> {
		busy = true;
		error = undefined;
		try {
			const apps = new DocumentDataSource<AppContent>('app', 'App');
			await apps.doc(data.app!.meta.id).update(payload);
			await invalidateAll();
			await goto(resolve(`/Configure/apps/new/review?app=${data.app!.meta.id}`));
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
	<title>{m.configure_apps_permissions_page_title()}</title>
</svelte:head>

{#if error}
	<AlertBanner
		message={error}
		details={errorDetails}
		dismissable
		onDismiss={() => (error = undefined)}
	/>
{/if}

<PermissionsForm
	app={data.app!}
	catalogue={data.catalogue as DoctypeCatalogueEntry[]}
	saving={busy}
	{onBack}
	{onContinue}
/>
