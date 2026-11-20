<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '../messages.js';
	import ChatPanel from '../chat/ChatPanel.svelte';
	import AssistantWindow from '../chat/AssistantWindow.svelte';
	import AssistantLauncher from '../chat/AssistantLauncher.svelte';
	import { HttpAssistantDriver } from '../driver/http-assistant-driver.js';
	import type { AssistantDriver } from '../driver/AssistantDriver.js';
	import type { Conversation } from '../driver/types.js';
	import {
		RAIL_WIDTH_DEFAULT,
		readAssistantRailWidth,
		writeAssistantRailWidth
	} from '../chat/assistantWindowState.js';

	/**
	 * Shared view for both custom elements — the wiring that scopes the chat
	 * core to one app's assistant:
	 *
	 * - the rail lists with the `context.kind__eq=app` + `context.app_id__eq`
	 *   filters (AND-combined with the backend's forced owner filter);
	 * - new conversations go through the driver's `createAppConversation`
	 *   (`POST /Api/assistant/app/conversations`) — the backend derives the
	 *   whole context from the authenticated caller;
	 * - the usage meter shows whenever the caller has a finite budget;
	 * - `403` (assistant unavailable for this app) renders the denial state;
	 *   `429` renders the budget notice on the turn.
	 *
	 * The two mounts differ only in their shell:
	 * - `floating` — the `AssistantWindow` shell (drag, maximize, collapse,
	 *   resize); `open` hides/shows it, persisted by the element.
	 * - inline — the panel fills the host container; the host owns layout.
	 *
	 * The driver defaults to an `HttpAssistantDriver` built from `baseUrl` +
	 * `fetch`; a host injects its own transport through the `driver` property.
	 */

	let {
		/** The Facet app (`app.App`) this assistant is scoped to. Required —
		 * the rail filter and the denial messaging hang off it. */
		appId,
		/** Facet origin (+ optional path prefix) for the default HTTP driver. */
		baseUrl = '',
		/** The host's authed fetch (cookie session, DPoP proof, bearer). */
		fetch: fetchImpl = undefined,
		/** BCP-47 language tag, baked into the backend's `## Language` block. */
		language = undefined,
		/** The configured assistant name — window header and turn header. */
		name = undefined,
		/** Transport override. Defaults to `HttpAssistantDriver(baseUrl, fetch)`. */
		driver = undefined,
		/** Floating mount: render the window shell. */
		floating = false,
		/** Floating mount: whether the window is open (the element persists it). */
		open = true,
		/** Floating mount: render the round launcher while the window is closed. */
		bubble = false,
		/** Floating mount: called when the user clicks the window's close (X). */
		onclose = undefined,
		/** Floating mount: called when the user clicks the launcher bubble. */
		onopen = undefined
	}: {
		appId: string;
		baseUrl?: string;
		fetch?: typeof fetch;
		language?: string;
		name?: string;
		driver?: AssistantDriver;
		floating?: boolean;
		open?: boolean;
		bubble?: boolean;
		onclose?: () => void;
		onopen?: () => void;
	} = $props();

	// A new driver only when the host injects none — rebuilt when the
	// baseUrl/fetch pair changes (a rare, host-driven event).
	const resolvedDriver = $derived(driver ?? new HttpAssistantDriver(baseUrl, fetchImpl));

	const assistantName = $derived(name ?? m.assistant_title());

	/** Context each rail fetch is scoped to: one app's conversations. */
	const context = $derived({ kind: 'app', app_id: appId });

	function createAppConversation(): Promise<Conversation> {
		return resolvedDriver.createAppConversation(language ? { language } : {});
	}

	// Conversation rail width — the drag logic lives inside ChatPanel; the
	// floating mount owns the persistence so it survives across sessions.
	// The inline mount does not persist (the host owns the layout).
	// svelte-ignore state_referenced_locally — intentional initial seeding.
	let railWidth = $state(floating ? readAssistantRailWidth() : RAIL_WIDTH_DEFAULT);

	// svelte-ignore state_referenced_locally — intentional initial seeding.
	let lastRailWidth = railWidth;
	$effect(() => {
		if (railWidth !== lastRailWidth) {
			lastRailWidth = railWidth;
			if (floating) writeAssistantRailWidth(railWidth);
		}
	});
</script>

{#if !floating || open}
	{#if floating}
		<AssistantWindow title={assistantName} {onclose}>
			<ChatPanel
				driver={resolvedDriver}
				context={{ ...context }}
				createConversation={createAppConversation}
				agentName={assistantName}
				placeholder={m.assistant_input_placeholder()}
				bind:railWidth
			/>
		</AssistantWindow>
	{:else}
		<div class="inline-root">
			<ChatPanel
				driver={resolvedDriver}
				context={{ ...context }}
				createConversation={createAppConversation}
				agentName={assistantName}
				placeholder={m.assistant_input_placeholder()}
			/>
		</div>
	{/if}
{:else if bubble}
	<AssistantLauncher label={assistantName} {onopen} />
{/if}

<style>
	/* The inline mount fills whatever container the host gives the element. */
	.inline-root {
		height: 100%;
		display: flex;
		flex-direction: column;
		min-height: 0;
	}
</style>
