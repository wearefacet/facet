<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import type { LayoutData } from '../$types';
	import CredentialsSuccess from '$lib/components/features/apps/CredentialsSuccess.svelte';
	import * as m from '$lib/paraglide/messages';

	/**
	 * Wizard credentials success screen. A thin page: it wires the
	 * CredentialsSuccess component to the published app and owns the
	 * navigation. The derivations, the API-key issuance, and the screen
	 * markup live in the component.
	 */

	let { data }: { data: LayoutData } = $props();

	function onGoToApp(): void {
		void goto(resolve('/Configure/apps/[slug]/overview', { slug: data.app!.data.slug }));
	}
</script>

<svelte:head>
	<title>
		{m.configure_apps_credentials_page_title({ name: data.app!.data.name })}
	</title>
</svelte:head>

<CredentialsSuccess
	app={data.app!.data}
	appId={data.app!.meta.id}
	issuerBase={data.issuerBase}
	{onGoToApp}
/>
