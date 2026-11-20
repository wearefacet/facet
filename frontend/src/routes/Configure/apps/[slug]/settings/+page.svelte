<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { goto, invalidateAll } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { DocumentDataSource } from '$lib/datasource/DocumentDataSource';
	import { toBannerError } from '$lib/datasource/bannerError.js';
	import type { AppContent } from '$lib/app/appTypes';
	import AppSettingsForm from '$lib/components/features/apps/AppSettingsForm.svelte';
	import AlertBanner from '$lib/components/primitives/content/AlertBanner.svelte';
	import type { LayoutData } from '../$types';
	import * as m from '$lib/paraglide/messages';

	/**
	 * App detail Settings tab — thin host for AppSettingsForm. The page
	 * owns the load data, the persistence (a flat content PATCH through the
	 * DataSource, then `invalidateAll()` so the next read reflects the
	 * saved state), the delete (confirm + navigate), and the error banner;
	 * the form renders.
	 */

	let { data }: { data: LayoutData } = $props();
	let app = $derived(data.app.data);
	let meta = $derived(data.app.meta);

	let error = $state<string | undefined>(undefined);
	let errorDetails = $state<string[]>([]);
	let busy = $state(false);

	async function patch(set: Record<string, unknown>): Promise<void> {
		busy = true;
		error = undefined;
		errorDetails = [];
		try {
			const apps = new DocumentDataSource<AppContent>('app', 'App');
			await apps.doc(meta.id).update(set);
			await invalidateAll();
		} catch (err) {
			const banner = toBannerError(err);
			error = banner.message;
			errorDetails = banner.details;
		} finally {
			busy = false;
		}
	}

	async function deleteApp(): Promise<void> {
		if (!confirm(m.configure_apps_delete_confirm({ name: app.name }))) return;
		busy = true;
		try {
			const apps = new DocumentDataSource<AppContent>('app', 'App');
			await apps.doc(meta.id).delete();
			await goto(resolve('/Configure/apps'));
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
	<title>{m.configure_apps_settings_page_title({ name: app.name })}</title>
</svelte:head>

<div class="settings">
	{#if error}
		<AlertBanner
			message={error}
			details={errorDetails}
			dismissable
			onDismiss={() => (error = undefined)}
		/>
	{/if}

	<AppSettingsForm {app} appId={meta.id} {busy} onSave={patch} onDelete={deleteApp} />
</div>

<style>
	.settings {
		display: flex;
		flex-direction: column;
		gap: 28px;
	}
</style>
