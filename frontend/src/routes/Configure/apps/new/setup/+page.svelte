<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { DocumentDataSource } from '$lib/datasource/DocumentDataSource';
	import { toBannerError } from '$lib/datasource/bannerError.js';
	import type { AppContent } from '$lib/app/appTypes';
	import type { LayoutData } from '../$types';
	import AlertBanner from '$lib/components/primitives/content/AlertBanner.svelte';
	import SetupForm from '$lib/components/features/apps/SetupForm.svelte';
	import * as m from '$lib/paraglide/messages';

	/**
	 * Wizard step 1 — setup. A thin page: it wires the SetupForm component
	 * to the loaded draft and owns the save and the navigation. The form
	 * state, the checks, and the step UI live in the component.
	 *
	 * On Continue the page creates the draft (no `app` param yet) or
	 * updates it (back-navigation from a later step). The created id moves
	 * forward as `?app=<id>`. Save failures render through the banner.
	 */

	let { data }: { data: LayoutData } = $props();

	let error = $state<string | undefined>(undefined);
	let errorDetails = $state<string[]>([]);
	let busy = $state(false);

	/**
	 * Slug uniqueness read for the form's debounced check. The list filter
	 * `slug__eq` returns at most one row (the slug is unique), so a
	 * non-empty result means the slug is taken.
	 */
	async function checkSlug(value: string): Promise<boolean> {
		try {
			const apps = new DocumentDataSource<AppContent>('app', 'App');
			const { data: rows } = await apps.list({ filters: { slug__eq: value } });
			return rows.length > 0;
		} catch {
			return false;
		}
	}

	async function onContinue(payload: Partial<AppContent>): Promise<void> {
		busy = true;
		error = undefined;
		try {
			const apps = new DocumentDataSource<AppContent>('app', 'App');
			if (data.app) {
				await apps.doc(data.app.meta.id).update(payload);
				await goto(resolve(`/Configure/apps/new/permissions?app=${data.app.meta.id}`));
			} else {
				const { meta } = await apps.create({
					...payload,
					status: 'draft',
					grants: []
				} as AppContent);
				await goto(resolve(`/Configure/apps/new/permissions?app=${meta.id}`), {
					replaceState: true
				});
			}
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
	<title>{m.configure_apps_setup_page_title()}</title>
</svelte:head>

{#if error}
	<AlertBanner
		message={error}
		details={errorDetails}
		dismissable
		onDismiss={() => (error = undefined)}
	/>
{/if}

<SetupForm
	app={data.app}
	issuerBase={data.issuerBase}
	currentAccount={data.currentAccount}
	saving={busy}
	{checkSlug}
	{onContinue}
/>
