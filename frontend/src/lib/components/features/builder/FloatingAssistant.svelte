<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import AssistantWindow from '$lib/components/features/chat/AssistantWindow.svelte';
	import ChatPanel from '$lib/components/features/chat/ChatPanel.svelte';
	import {
		HttpAssistantDriver,
		type Conversation,
		type GoToPageArgs
	} from '$lib/assistant/index.js';
	import { page } from '$app/state';
	import { goto } from '$app/navigation';
	import { resolve } from '$app/paths';
	import { getDomainLabel } from '$lib/navState.svelte';
	import {
		readAssistantRailWidth,
		writeAssistantRailWidth
	} from '$lib/components/features/chat/assistantWindowState.js';

	/**
	 * Builder assistant — the `AssistantWindow` surface for draft work.
	 *
	 * The window shell (drag, collapse, maximize, resize, header chrome)
	 * lives in `AssistantWindow` (`features/chat/`); this mount owns the
	 * builder-specific glue: the draft-scoped conversation factory, the
	 * page context derived from the URL, `go_to_page` execution,
	 * and the draft badge / daymark.
	 *
	 * It mounts in two situations: the `/Builder` editor routes, and any
	 * route while a preview session is active — the user keeps iterating on
	 * the draft from the chat window while the preview shows the draft's
	 * live application. The page-context chip and `go_to_page` handle both
	 * path shapes (builder editor routes and the draft's live routes).
	 *
	 * On the Builder index no draft is selected (`draftDomain` is empty).
	 * The window then shows a note instead of the chat: the composer and
	 * the conversation factory stay unmounted, so no conversation creation
	 * can fire against an empty draft domain.
	 */

	let {
		draftDomain,
		/** The configured assistant name — window header and turn header. */
		name = m.assistant_title(),
		/** Whether an AI provider is configured for the installation. `false`
		 * disables conversation creation with an explanatory message. */
		configured = true,
		onclose
	}: {
		/** Draft domain id this panel is scoped to. */
		draftDomain: string;
		/** The configured assistant name. */
		name?: string;
		/** Whether an AI provider is configured for the installation. */
		configured?: boolean;
		/** Called when the user clicks the close (X) button. */
		onclose?: () => void;
	} = $props();

	const driver = new HttpAssistantDriver();

	const assistantContext = $derived({ kind: 'domain-builder', draft_domain: draftDomain });

	/** Display label for the scope badge and thread daymark — the nav
	 * model's draft label (e.g. "CRM (draft)"); falls back to the raw id
	 * while the draft nav has not loaded. */
	const draftLabel = $derived.by(() => (draftDomain ? getDomainLabel(draftDomain) : ''));

	/** Conversation factory: binds each new conversation to this draft. */
	function createBuilderConversation(): Promise<Conversation> {
		return driver.createDomainBuilderConversation({ draft_domain: draftDomain });
	}

	/** Context chip text — reflects where the user is currently looking. */
	const contextHint = $derived.by(() => {
		const segs = page.url.pathname.split('/').filter(Boolean);
		if (segs.length === 0) return '';
		if (segs[0] !== 'Builder') {
			// Live route — the preview session has navigated the user onto the
			// draft's own application (`/{draft}/{Doctype}/{id}`). Surface the
			// same where-am-I context from the live path so the model sees what
			// the user is looking at while it edits the schema.
			const parts: string[] = [getDomainLabel(segs[0])];
			if (segs[1]) parts.push(`· ${segs[1]}`);
			if (segs[2]) parts.push(`· ${segs[2]}`);
			return parts.join(' ');
		}
		// The second segment is the draft domain id — show its display label
		// (e.g. "Supplier (draft)") instead of the temp id.
		const parts: string[] = [getDomainLabel(segs[1])];
		const domainTabs = new Set(['overview', 'doctypes', 'grants', 'check']);
		if (segs.length >= 3 && !domainTabs.has(segs[2])) {
			// Doctype editor: /Builder/[draft]/[doctype]/[tab]
			parts.push(`· ${segs[2]}`);
			if (segs[3]) parts.push(`· ${segs[3]}`);
			const field = page.url.searchParams.get('field');
			if (field) parts.push(`· ${field}`);
		} else if (segs.length >= 3) {
			// Domain editor: /Builder/[draft]/[tab]
			parts.push(`· ${segs[2]}`);
		}
		return parts.join(' ');
	});

	function formatPageContext(): string {
		return contextHint ? `[Page context: Viewing: ${contextHint}]` : '';
	}

	/** Executes the `go_to_page` UI tool inside the builder. The draft comes
	 * from the bound conversation, never from the tool payload — a forged id
	 * must not redirect the user to another domain. Only the live stream
	 * reaches this — replayed turns go through `reconstructTurns`, so history
	 * never re-navigates. Doctype ids may be qualified (`domain.Name`) — the
	 * builder route matches the bare doctype name, so the last segment is used. */
	function navigateBuilder(args: GoToPageArgs): void {
		if (!draftDomain) return;
		switch (args.page) {
			case 'overview':
				void goto(resolve('/Builder/[draftDomain]/(editor)/overview', { draftDomain }));
				break;
			case 'doctypes':
				void goto(resolve('/Builder/[draftDomain]/(editor)/doctypes', { draftDomain }));
				break;
			case 'check':
				void goto(resolve('/Builder/[draftDomain]/(editor)/check', { draftDomain }));
				break;
			case 'grants':
				void goto(resolve('/Builder/[draftDomain]/(editor)/grants', { draftDomain }));
				break;
			case 'doctype': {
				const name = args.doctype_id?.split('.').pop();
				if (!name) return;
				void goto(
					resolve('/Builder/[draftDomain]/[doctype]/[[tab]]', {
						draftDomain,
						doctype: name,
						tab: args.tab ?? 'fields'
					})
				);
				break;
			}
			case 'preview': {
				// `resolve` throws on a rest param given `undefined`; '' produces
				// the bare `/Builder/{draft}/preview` entry URL.
				const path = args.path?.length ? args.path.map(encodeURIComponent).join('/') : '';
				void goto(resolve('/Builder/[draftDomain]/preview/[...path]', { draftDomain, path }));
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

<AssistantWindow title={name} badge={draftLabel} {onclose}>
	{#if draftDomain}
		<ChatPanel
			{driver}
			context={{ ...assistantContext }}
			createConversation={createBuilderConversation}
			pageContext={formatPageContext}
			navigate={navigateBuilder}
			{contextHint}
			{configured}
			daymark={draftLabel}
			agentName={name}
			agentTag={m.assistant_tag_schema()}
			bind:railWidth
		/>
	{:else}
		<div class="no-draft-note">{m.assistant_builder_empty_hint()}</div>
	{/if}
</AssistantWindow>

<style>
	/* The window body is a flex column; the note fills it like ChatPanel. */
	.no-draft-note {
		flex: 1;
		display: grid;
		place-items: center;
		padding: 24px;
		text-align: center;
		font-size: 13.5px;
		line-height: 1.5;
		color: var(--text-3);
	}
</style>
