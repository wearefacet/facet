<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import FloatingAssistant from '$lib/components/features/builder/FloatingAssistant.svelte';
	import WorkspaceAssistant from '$lib/components/features/chat/WorkspaceAssistant.svelte';
	import { getAssistantOpen, setAssistantOpen } from '$lib/assistantOpen.svelte';

	let {
		surface,
		draftDomain,
		accountId,
		name = m.assistant_title(),
		assistantConfigured = true
	}: {
		/** Which assistant mount the current route gets. `null` mounts
		 *  nothing — Configure (own shell), the consent page, and
		 *  unauthenticated routes render no assistant. */
		surface: 'builder' | 'workspace' | null;
		/** Draft domain id for the builder surface. */
		draftDomain: string;
		/** Account id for the workspace surface. */
		accountId: string;
		/** The configured assistant name both surfaces render. */
		name?: string;
		/** Whether an AI provider is configured for the installation (an API
		 *  key resolves). `false` keeps the dock visible but disables
		 *  conversation creation with an explanatory message. */
		assistantConfigured?: boolean;
	} = $props();
</script>

{#if surface && getAssistantOpen()}
	{#if surface === 'builder'}
		<!-- FloatingAssistant is position:fixed, so it floats over the AppShell
			regardless of the grid layout. Rendered outside AppShell so the
			AppShell's grid no longer needs the 3rd assistant column. -->
		<FloatingAssistant
			{draftDomain}
			{name}
			configured={assistantConfigured}
			onclose={() => setAssistantOpen(false)}
		/>
	{:else}
		<!-- WorkspaceAssistant is the same floating window the builder mounts —
			position:fixed, so it floats over the live application. -->
		<WorkspaceAssistant
			{accountId}
			{name}
			configured={assistantConfigured}
			onclose={() => setAssistantOpen(false)}
		/>
	{/if}
{/if}
