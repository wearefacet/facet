<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { goto, invalidateAll } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { toBannerError } from '$lib/datasource/bannerError.js';
	import { uploadDeployment, type DeployFile } from '$lib/app/deployments';
	import DeployPanel from '$lib/components/features/apps/DeployPanel.svelte';
	import AlertBanner from '$lib/components/primitives/content/AlertBanner.svelte';
	import type { LayoutData } from '../$types';
	import * as m from '$lib/paraglide/messages';

	/**
	 * Deploy flow — thin host for DeployPanel. The page owns the upload
	 * (one multipart request to `POST /Api/app/:id/deploy`), the error
	 * banner, and the navigation (success returns to the detail page); the
	 * panel renders the pickers, the path manifest, and the options.
	 */

	let { data }: { data: LayoutData } = $props();

	let app = $derived(data.app.data);

	let busy = $state(false);
	let error = $state<string | undefined>(undefined);
	let errorDetails = $state<string[]>([]);

	async function deploy(input: {
		files: DeployFile[];
		note: string;
		spa: boolean;
		activate: boolean;
	}): Promise<void> {
		busy = true;
		error = undefined;
		errorDetails = [];
		try {
			await uploadDeployment(data.appId, input);
			await invalidateAll();
			await goto(resolve('/Configure/apps/[slug]', { slug: data.slug }));
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
	<title>{m.configure_apps_deploy_page_title({ name: app.name })}</title>
</svelte:head>

<div class="deploy">
	{#if error}
		<AlertBanner
			message={error}
			details={errorDetails}
			dismissable
			onDismiss={() => (error = undefined)}
		/>
	{/if}

	<DeployPanel
		{busy}
		onDeploy={deploy}
		onCancel={() => goto(resolve('/Configure/apps/[slug]', { slug: data.slug }))}
	/>
</div>

<style>
	.deploy {
		display: flex;
		flex-direction: column;
		gap: 20px;
	}
</style>
