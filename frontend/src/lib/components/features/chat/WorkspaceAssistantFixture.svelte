<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	// The window component binds at module level so the instance script stays
	// focused on state ownership.
	import WorkspaceAssistant from './WorkspaceAssistant.svelte';
</script>

<script lang="ts">
	/**
	 * Stories fixture — the mount composition the root layout owns: an
	 * `AppShell` whose top-bar toggle renders only when the account holds
	 * assistant access, plus the `WorkspaceAssistant` mounted while open.
	 *
	 * Open state is hydrated from sessionStorage on mount and persisted on
	 * every change — the same `facet.assistant.open` contract as the layout.
	 * A remount of this fixture therefore re-derives the state from storage,
	 * which is what the persistence story asserts.
	 */
	import AppShell from '$lib/components/primitives/surfaces/AppShell.svelte';
	import type { AssistantDriver } from '$lib/assistant/index.js';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { Crumb } from '$lib/components/primitives/surfaces/Topbar.svelte';

	let {
		/** Workspace-assistant availability (`me.assistant.access`). */
		access = false,
		/** Conversation data source for the dock. */
		driver = undefined,
		/** Data driver for the workspace document surfaces. */
		documentDriver = undefined,
		/** Account id the dock's list filters on. */
		accountId,
		/** Crumb trail shown in the top bar. */
		crumbs = [{ label: 'Dashboard' }] as Crumb[]
	}: {
		access?: boolean;
		driver?: AssistantDriver;
		documentDriver?: DataDriver;
		accountId: string;
		crumbs?: Crumb[];
	} = $props();

	let open = $state(
		typeof window !== 'undefined'
			? (() => {
					try {
						return window.sessionStorage.getItem('facet.assistant.open') === 'true';
					} catch {
						return false;
					}
				})()
			: false
	);

	// Persist on change — the layout's contract.
	$effect(() => {
		if (typeof window === 'undefined') return;
		try {
			window.sessionStorage.setItem('facet.assistant.open', open ? 'true' : 'false');
		} catch {
			/* storage disabled — the in-memory state still wins */
		}
	});

	function toggle() {
		open = !open;
	}
</script>

<AppShell {crumbs} assistantAvailable={access} assistantOpen={open} ontoggleassistant={toggle}>
	<div class="page">
		<p>Workspace page</p>
	</div>
</AppShell>

{#if open && access}
	<!-- The layout gates the window on access as well, so a persisted open
		state never mounts a window for an account without it. -->
	<WorkspaceAssistant {accountId} {driver} {documentDriver} onclose={() => (open = false)} />
{/if}

<style>
	.page {
		min-height: 200px;
	}
</style>
