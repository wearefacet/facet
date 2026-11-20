<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { goto, invalidateAll } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { DocumentDataSource } from '$lib/datasource/DocumentDataSource';
	import { toBannerError } from '$lib/datasource/bannerError.js';
	import type { AppContent } from '$lib/app/appTypes';
	import type { LayoutData } from '../$types';
	import AlertBanner from '$lib/components/primitives/content/AlertBanner.svelte';
	import ReviewPanel from '$lib/components/features/apps/ReviewPanel.svelte';
	import * as m from '$lib/paraglide/messages';

	/**
	 * Wizard review step. A thin page: it wires the ReviewPanel component
	 * to the loaded draft and owns the status save and the navigation.
	 * Publish writes `status: 'active'` and moves to the credentials
	 * success screen — the highest-value moment in the flow, where the
	 * `client_id`, the sign-in address, and the client snippet show. "Keep
	 * as draft" writes `status: 'draft'` and moves to the overview. The
	 * checklist, the consent preview, and the publish gate live in the
	 * component.
	 */

	let { data }: { data: LayoutData } = $props();

	let error = $state<string | undefined>(undefined);
	let errorDetails = $state<string[]>([]);
	let busy = $state<'draft' | 'publish' | undefined>(undefined);

	async function back(): Promise<void> {
		await goto(resolve(`/Configure/apps/new/permissions?app=${data.app!.meta.id}`));
	}

	async function finish(status: 'draft' | 'active'): Promise<void> {
		busy = status === 'active' ? 'publish' : 'draft';
		error = undefined;
		try {
			const apps = new DocumentDataSource<AppContent>('app', 'App');
			await apps.doc(data.app!.meta.id).update({ status });
			await invalidateAll();
			if (status === 'active') {
				await goto(resolve(`/Configure/apps/new/credentials?app=${data.app!.meta.id}`));
			} else {
				await goto(resolve('/Configure/apps/[slug]/overview', { slug: data.app!.data.slug }));
			}
		} catch (err) {
			const banner = toBannerError(err);
			error = banner.message;
			errorDetails = banner.details;
		} finally {
			busy = undefined;
		}
	}
</script>

<svelte:head>
	<title>{m.configure_apps_review_page_title()}</title>
</svelte:head>

{#if error}
	<AlertBanner
		message={error}
		details={errorDetails}
		dismissable
		onDismiss={() => (error = undefined)}
	/>
{/if}

<ReviewPanel
	app={data.app!.data}
	appId={data.app!.meta.id}
	catalogue={data.catalogue ?? []}
	{busy}
	onBack={back}
	onFinish={finish}
/>
