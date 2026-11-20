<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { goto, invalidateAll } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { DocumentDataSource } from '$lib/datasource/DocumentDataSource';
	import { toBannerError } from '$lib/datasource/bannerError.js';
	import type { AppContent } from '$lib/app/appTypes';
	import type { DeploymentRow } from '$lib/app/deployments';
	import CredentialsPanel from '$lib/components/features/apps/CredentialsPanel.svelte';
	import AlertBanner from '$lib/components/primitives/content/AlertBanner.svelte';
	import type { PageData } from './$types';
	import * as m from '$lib/paraglide/messages';

	/**
	 * App detail Overview tab — thin host for CredentialsPanel. The page
	 * owns the load data, the lifecycle and deployment mutations (they
	 * route through the DataSource so the show cache invalidates on
	 * success), the error banner, and the navigation; the panel renders.
	 * Permission gating (`can('app.App', action)`) runs inside the panel
	 * because the manifest may not grant every action to every role.
	 */

	let { data }: { data: PageData } = $props();

	let app = $derived(data.app.data);
	let meta = $derived(data.app.meta);
	let deployments = $derived(data.deployments);

	let activatingId = $state<string | undefined>(undefined);
	let error = $state<string | undefined>(undefined);
	let errorDetails = $state<string[]>([]);
	let busy = $state(false);

	async function activate(row: DeploymentRow): Promise<void> {
		activatingId = row.meta.id;
		error = undefined;
		errorDetails = [];
		try {
			const apps = new DocumentDataSource<AppContent>('app', 'App');
			await apps.doc(meta.id).update({
				active_deployment: `app.Deployment.${row.meta.id}`
			});
			await invalidateAll();
		} catch (err) {
			const banner = toBannerError(err);
			error = banner.message;
			errorDetails = banner.details;
		} finally {
			activatingId = undefined;
		}
	}

	async function setStatus(status: 'active' | 'disabled'): Promise<void> {
		busy = true;
		error = undefined;
		errorDetails = [];
		try {
			const apps = new DocumentDataSource<AppContent>('app', 'App');
			await apps.doc(meta.id).update({ status });
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
	<title>{m.configure_apps_overview_page_title({ name: app.name })}</title>
</svelte:head>

<div class="overview">
	{#if error}
		<AlertBanner
			message={error}
			details={errorDetails}
			dismissable
			onDismiss={() => (error = undefined)}
		/>
	{/if}

	<CredentialsPanel
		{app}
		{deployments}
		{activatingId}
		{busy}
		onActivateDeployment={activate}
		onSetStatus={setStatus}
		onDelete={deleteApp}
		onDeploy={() => goto(resolve('/Configure/apps/[slug]/deploy', { slug: app.slug }))}
	/>
</div>

<style>
	.overview {
		display: flex;
		flex-direction: column;
		gap: 24px;
	}
</style>
