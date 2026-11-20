<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import AssistantWindow from '$lib/components/features/chat/AssistantWindow.svelte';
	import ChatPanel from '$lib/components/features/chat/ChatPanel.svelte';
	import { goto } from '$app/navigation';
	import {
		HttpAssistantDriver,
		type AssistantDriver,
		type Conversation,
		type NavigateTargetArgs
	} from '$lib/assistant/index.js';
	import { resolve } from '$app/paths';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import {
		readAssistantRailWidth,
		writeAssistantRailWidth
	} from '$lib/components/features/chat/assistantWindowState.js';

	/**
	 * Workspace assistant — the `AssistantWindow` surface in the main
	 * application. The same floating window the builder mounts: drag,
	 * collapse, maximize, edge resize, persisted window state.
	 *
	 * One mount of `ChatPanel`, scoped to the signed-in account: both the
	 * conversation list and every new conversation filter on
	 * `{kind: 'workspace', created_by}` so builder conversations never leak
	 * in (and vice versa). The root layout renders the window on
	 * authenticated non-builder, non-Configure routes when the account holds
	 * a role with `assistant_access`; the open state lives in `sessionStorage`
	 * (`facet.assistant.open`) and stays owned by the layout, exactly like
	 * the builder's floating-window state.
	 *
	 * Conversation creation and streaming run against the dedicated workspace
	 * routes; the backend re-checks access on both. A workspace `navigate`
	 * call opens its target in the main application — the URL derives from
	 * the tool payload here (unlike the builder, where the draft domain comes
	 * from the UI), so an unreadable target lands on the app's own 404/403
	 * surface.
	 */

	let {
		/** Signed-in account id — scopes the conversation list and new
		 * conversations to their owner. */
		accountId,
		/** The configured assistant name — window header and turn header. */
		name = m.assistant_title(),
		/** Whether an AI provider is configured for the installation. `false`
		 * disables conversation creation with an explanatory message. */
		configured = true,
		/** Data source. Defaults to the HTTP driver; stories inject the mock. */
		driver = new HttpAssistantDriver(),
		/** Data driver for the workspace document surfaces. Defaults to the
		 * HTTP driver; stories inject a mock. */
		documentDriver = undefined,
		/** Called when the user clicks the close (X) button. */
		onclose = undefined
	}: {
		accountId: string;
		name?: string;
		configured?: boolean;
		driver?: AssistantDriver;
		documentDriver?: DataDriver;
		onclose?: () => void;
	} = $props();

	const workspaceContext = $derived({ kind: 'workspace', created_by: accountId });

	function createWorkspaceConversation(): Promise<Conversation> {
		return driver.createWorkspaceConversation();
	}

	/** Opens a workspace `navigate` target in the main application. The URL
	 * derives from the tool payload here (unlike the builder, where the draft
	 * domain comes from the UI), so an unreadable target lands on the app's
	 * own 404/403 surface. Values are encoded before substitution — `resolve`
	 * populates params verbatim. */
	function openWorkspaceTarget(target: NavigateTargetArgs): void {
		if (!target.domain) return;
		const domain = encodeURIComponent(target.domain);
		switch (target.target) {
			case 'domain':
				void goto(resolve('/[domain=notApi]', { domain }));
				break;
			case 'collection': {
				if (!target.doctype) return;
				const params = { domain, doctype: encodeURIComponent(target.doctype) };
				const id: '/[domain=notApi]/[doctype]' | `/[domain=notApi]/[doctype]?view=${string}` =
					target.view_slug
						? `/[domain=notApi]/[doctype]?view=${encodeURIComponent(target.view_slug)}`
						: '/[domain=notApi]/[doctype]';
				void goto(resolve(id, params));
				break;
			}
			case 'document': {
				if (!target.doctype || !target.id) return;
				void goto(
					resolve('/[domain=notApi]/[doctype]/[id]', {
						domain,
						doctype: encodeURIComponent(target.doctype),
						id: encodeURIComponent(target.id)
					})
				);
				break;
			}
		}
	}

	// Conversation rail width — the drag logic lives inside ChatPanel; this
	// mount owns the persistence so it survives across sessions.
	let railWidth = $state(readAssistantRailWidth());

	// svelte-ignore state_referenced_locally — intentional initial seeding.
	let lastRailWidth = railWidth;
	$effect(() => {
		if (railWidth !== lastRailWidth) {
			lastRailWidth = railWidth;
			writeAssistantRailWidth(railWidth);
		}
	});
</script>

<AssistantWindow title={name} {onclose}>
	<ChatPanel
		{driver}
		context={{ ...workspaceContext }}
		createConversation={createWorkspaceConversation}
		navigateWorkspace={openWorkspaceTarget}
		{documentDriver}
		{configured}
		agentName={name}
		agentTag={m.assistant_tag_workspace()}
		placeholder={m.assistant_workspace_placeholder()}
		bind:railWidth
	/>
</AssistantWindow>
