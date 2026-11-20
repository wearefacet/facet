<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '../messages.js';
	import Archive from '@lucide/svelte/icons/archive';
	import ArchiveRestore from '@lucide/svelte/icons/archive-restore';
	import PanelLeftClose from '@lucide/svelte/icons/panel-left-close';
	import RelativeTime from './RelativeTime.svelte';
	import type { AssistantDriver } from '../driver/AssistantDriver.js';
	import type { Conversation, ListConversationsParams } from '../driver/types.js';

	/**
	 * A scrollable list of assistant conversations, scoped to a context.
	 *
	 * Wires an {@link AssistantDriver} to `listConversations` with infinite
	 * pagination: as the user nears the bottom of the scroll viewport, the
	 * next page is fetched and appended. The `context` prop is compiled to
	 * `context.<key>__eq` filters so callers can scope the list. The list
	 * is ordered by `updated_at DESC` on the backend so the conversation with
	 * the most recently added turn surfaces first.
	 *
	 * Archive: the default list is live-only. A small header toggle swaps the
	 * list to the archived conversations, and a row hover action archives or
	 * unarchives. The toggle is view state — it resets on reload. A new turn
	 * unarchives server-side, so an archived conversation comes back to the
	 * default list on its next activity.
	 */
	let {
		driver,
		/** Context filter — each key becomes `context.<key>__eq=<value>`. */
		context = {},
		/** Selected conversation id. Drives the active row highlight. */
		selectedId = undefined,
		/** Page size for each fetch. */
		pageSize = 50,
		/** Bump to force a reload from page 1 (e.g. after a turn lands). */
		reloadKey = 0,
		/** Called when the user picks a conversation. */
		onselect = (_c: Conversation) => {},
		/** Called when the user clicks "New conversation". */
		onnew = undefined,
		/** Called when the user clicks the collapse button in the rail header. */
		oncollapse = undefined
	}: {
		driver: AssistantDriver;
		context?: Record<string, unknown>;
		selectedId?: string;
		pageSize?: number;
		reloadKey?: number;
		onselect?: (conversation: Conversation) => void;
		onnew?: () => void;
		/** Hides the conversation rail (the caller renders a thin expand edge
		 * when collapsed so the user can re-open it). */
		oncollapse?: () => void;
	} = $props();

	let conversations = $state<Conversation[]>([]);
	let loading = $state(false);
	let loadingMore = $state(false);
	let error = $state<string | null>(null);
	let more = $state(false);
	let page = $state(1);

	/** When true, the rail lists the archived conversations instead of the
	 * live ones. In-memory view state — the default is live-only. */
	let showArchived = $state(false);
	/** Id of the row with an archive/unarchive request in flight. */
	let workingId = $state<string | null>(null);

	let scrollEl = $state<HTMLElement | null>(null);

	const filters = $derived.by(() => {
		const f: Record<string, string> = {};
		for (const [key, value] of Object.entries(context)) {
			f[`context.${key}__eq`] = String(value);
		}
		if (showArchived) f['archived__eq'] = 'true';
		return f;
	});

	const baseParams = $derived<ListConversationsParams>({
		filters,
		sort: ['-updated_at'],
		items: pageSize
	});

	// Initial load + reload when the context filter or `reloadKey` changes.
	$effect(() => {
		// Track these reactive deps so a context/reloadKey change re-fetches
		// from page 1.
		void baseParams;
		void reloadKey;
		page = 1;
		conversations = [];
		more = false;
		error = null;
		loading = true;
		loadPage(1, true)
			.catch((e) => {
				error = (e as Error).message;
			})
			.finally(() => {
				loading = false;
			});
	});

	async function loadPage(targetPage: number, replace: boolean): Promise<void> {
		const result = await driver.listConversations({ ...baseParams, page: targetPage });
		if (replace) {
			conversations = result.data;
		} else {
			// De-dup by id in case the backend's sort ties across page boundaries.
			const seen = new Set(conversations.map((c) => c.id));
			conversations = [...conversations, ...result.data.filter((c) => !seen.has(c.id))];
		}
		more = result.meta.more;
		page = targetPage;
	}

	// Infinite scroll: when the user nears the bottom and there are more
	// pages, fetch the next one. We do NOT auto-follow like ChatScroll — the
	// list must stay put while new rows append above the fold.
	function onScroll() {
		if (!scrollEl || loading || loadingMore || !more) return;
		const { scrollTop, clientHeight, scrollHeight } = scrollEl;
		if (scrollTop + clientHeight >= scrollHeight - 80) {
			loadingMore = true;
			loadPage(page + 1, false)
				.catch((e) => {
					error = (e as Error).message;
				})
				.finally(() => {
					loadingMore = false;
				});
		}
	}

	function excerpt(conv: Conversation): string {
		const kind = typeof conv.context?.kind === 'string' ? conv.context.kind : '';
		if (kind) return m.assistant_conversation_excerpt({ kind });
		return m.assistant_conversation_fallback();
	}

	function kindLabel(conv: Conversation): string | null {
		const kind = typeof conv.context?.kind === 'string' ? conv.context.kind : '';
		return kind || null;
	}

	/** Archives a live row, unarchives an archived one, then reloads so the
	 * row moves to the other list. The open conversation stays open — archive
	 * changes list membership only. */
	async function toggleArchive(conv: Conversation, e: MouseEvent) {
		e.stopPropagation();
		if (workingId) return;
		workingId = conv.id;
		try {
			await driver.setConversationArchived(conv.id, conv.archived_at == null);
			await loadPage(1, true);
		} catch (err) {
			error = (err as Error).message;
		} finally {
			workingId = null;
		}
	}
</script>

<div class="cl">
	<header class="cl-head">
		<span class="cl-title">{m.assistant_conversations_title()}</span>
		<div class="cl-head-actions">
			{#if onnew}
				<button class="cl-new" onclick={onnew} title={m.assistant_new_conversation()}>
					{m.assistant_conversations_new()}
				</button>
			{/if}
			<button
				class="cl-icon-btn"
				class:cl-icon-btn-on={showArchived}
				type="button"
				onclick={() => (showArchived = !showArchived)}
				aria-pressed={showArchived}
				aria-label={m.assistant_conversations_show_archived()}
				title={m.assistant_conversations_show_archived()}
			>
				<Archive size={14} stroke-width={1.9} />
			</button>
			{#if oncollapse}
				<button
					class="cl-icon-btn"
					type="button"
					onclick={oncollapse}
					aria-label={m.assistant_conversations_hide()}
					title={m.assistant_conversations_hide()}
				>
					<PanelLeftClose size={14} stroke-width={1.9} />
				</button>
			{/if}
		</div>
	</header>

	<div bind:this={scrollEl} class="cl-scroll" onscroll={onScroll}>
		{#if loading && conversations.length === 0}
			<ul class="cl-list" aria-busy="true">
				{#each Array(6) as _, i (i)}
					<li class="cl-row cl-skeleton" aria-hidden="true">
						<div class="cl-row-main">
							<div class="cl-skel-line cl-skel-wide"></div>
							<div class="cl-skel-line cl-skel-narrow"></div>
						</div>
					</li>
				{/each}
			</ul>
		{:else if error}
			<div class="cl-empty cl-error" role="alert">{error}</div>
		{:else if conversations.length === 0}
			<div class="cl-empty">
				{showArchived
					? m.assistant_conversations_archived_empty()
					: m.assistant_conversations_empty()}
			</div>
		{:else}
			<ul class="cl-list">
				{#each conversations as conv (conv.id)}
					<li class="cl-item">
						<button
							class="cl-row"
							class:cl-row-active={conv.id === selectedId}
							onclick={() => onselect(conv)}
						>
							<div class="cl-row-main">
								<div class="cl-row-top">
									<span class="cl-excerpt">{excerpt(conv)}</span>
									{#if kindLabel(conv)}
										<span class="cl-kind">{kindLabel(conv)}</span>
									{/if}
								</div>
								<div class="cl-row-bottom">
									<span class="cl-id" title={conv.id}>{conv.id.slice(-8)}</span>
									<RelativeTime class="cl-time" date={conv.updated_at} />
								</div>
							</div>
						</button>
						<button
							class="cl-row-action"
							type="button"
							disabled={workingId !== null}
							onclick={(e) => toggleArchive(conv, e)}
							aria-label={conv.archived_at
								? m.assistant_conversations_unarchive()
								: m.assistant_conversations_archive()}
							title={conv.archived_at
								? m.assistant_conversations_unarchive()
								: m.assistant_conversations_archive()}
						>
							{#if conv.archived_at}
								<ArchiveRestore size={13} stroke-width={1.9} />
							{:else}
								<Archive size={13} stroke-width={1.9} />
							{/if}
						</button>
					</li>
				{/each}
			</ul>
			{#if loadingMore}
				<div class="cl-more">{m.assistant_conversations_loading_more()}</div>
			{:else if !more}
				<div class="cl-end">{m.assistant_conversations_end()}</div>
			{/if}
		{/if}
	</div>
</div>

<style>
	.cl {
		display: flex;
		flex-direction: column;
		height: 100%;
		min-height: 0;
		background: var(--facet-surface);
		border-right: 1px solid var(--facet-border);
	}

	.cl-head {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 8px;
		padding: 10px 12px;
		border-bottom: 1px solid var(--facet-border);
		flex-shrink: 0;
	}

	.cl-title {
		font-family: var(--facet-font-display);
		font-size: 13px;
		font-weight: 600;
		color: var(--facet-text);
		letter-spacing: 0.01em;
		min-width: 0;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.cl-new {
		border: 1px solid var(--facet-border-strong, var(--facet-border));
		background: var(--facet-surface);
		color: var(--facet-text-2);
		border-radius: var(--facet-r-sm);
		padding: 3px 8px;
		font-size: 11.5px;
		font-weight: 500;
		cursor: pointer;
		flex-shrink: 0;
		transition:
			background 0.12s ease,
			color 0.12s ease;
	}

	.cl-new:hover {
		background: var(--facet-accent-weak);
		color: var(--facet-accent-ink);
		border-color: var(--facet-accent);
	}

	.cl-head-actions {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		flex-shrink: 0;
	}

	.cl-icon-btn {
		display: grid;
		place-items: center;
		width: 24px;
		height: 24px;
		border: none;
		border-radius: var(--facet-r-sm);
		background: transparent;
		color: var(--facet-text-3);
		cursor: pointer;
		flex-shrink: 0;
		transition:
			background 0.12s ease,
			color 0.12s ease;
	}

	.cl-icon-btn:hover {
		background: var(--facet-sunken);
		color: var(--facet-text);
	}

	/* The "show archived" toggle in its on state. */
	.cl-icon-btn-on,
	.cl-icon-btn-on:hover {
		background: var(--facet-accent-weak);
		color: var(--facet-accent-ink);
	}

	.cl-scroll {
		flex: 1;
		overflow-y: auto;
		min-height: 0;
	}

	.cl-list {
		list-style: none;
		margin: 0;
		padding: 0;
	}

	.cl-item {
		position: relative;
	}

	/* Row archive action — a sibling button over the row's right edge. It
	 * stays out of the pointer flow until hover or keyboard focus so the
	 * row stays a single click target otherwise. */
	.cl-row-action {
		position: absolute;
		right: 8px;
		top: 50%;
		transform: translateY(-50%);
		display: grid;
		place-items: center;
		width: 24px;
		height: 24px;
		border: none;
		border-radius: var(--facet-r-sm);
		background: var(--facet-surface-2);
		color: var(--facet-text-3);
		cursor: pointer;
		opacity: 0;
		pointer-events: none;
		transition:
			opacity 0.12s ease,
			background 0.12s ease,
			color 0.12s ease;
	}

	.cl-item:hover .cl-row-action,
	.cl-item:focus-within .cl-row-action {
		opacity: 1;
		pointer-events: auto;
	}

	.cl-row-action:hover {
		background: var(--facet-sunken);
		color: var(--facet-text);
	}

	.cl-row-action:focus-visible {
		outline: 2px solid var(--facet-accent);
		outline-offset: -2px;
	}

	.cl-row-action:disabled {
		cursor: default;
		opacity: 0.5;
	}

	.cl-row {
		width: 100%;
		display: block;
		text-align: left;
		background: transparent;
		border: none;
		border-bottom: 1px solid var(--facet-border);
		padding: 11px 16px;
		cursor: pointer;
		transition: background 0.1s ease;
	}

	.cl-row:hover {
		background: var(--facet-surface-2);
	}

	.cl-row:focus-visible {
		outline: 2px solid var(--facet-accent);
		outline-offset: -2px;
	}

	.cl-row-active {
		background: var(--facet-accent-weak);
	}

	.cl-row-active:hover {
		background: var(--facet-accent-weak);
	}

	.cl-row-main {
		display: flex;
		flex-direction: column;
		gap: 4px;
	}

	.cl-row-top {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 8px;
	}

	.cl-excerpt {
		font-size: 13px;
		font-weight: 500;
		color: var(--facet-text);
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.cl-kind {
		flex-shrink: 0;
		font-size: 10.5px;
		font-weight: 600;
		letter-spacing: 0.02em;
		color: var(--facet-accent-ink);
		background: var(--facet-accent-weak);
		border-radius: var(--facet-r-pill);
		padding: 2px 7px;
	}

	.cl-row-bottom {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 8px;
		font-size: 11.5px;
		color: var(--facet-text-3);
		font-family: var(--facet-font-mono);
	}

	.cl-id {
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.cl-row-bottom :global(.cl-time) {
		flex-shrink: 0;
	}

	.cl-empty,
	.cl-more,
	.cl-end,
	.cl-error {
		padding: 16px;
		font-size: 12.5px;
		color: var(--facet-text-3);
		text-align: center;
	}

	.cl-error {
		color: var(--facet-danger);
	}

	.cl-more {
		color: var(--facet-text-2);
	}

	/* Skeleton placeholders for the loading state. */
	.cl-skeleton {
		cursor: default;
		pointer-events: none;
	}

	.cl-skel-line {
		height: 10px;
		border-radius: var(--facet-r-sm);
		background: var(--facet-sunken);
		animation: cl-skel-pulse 1.4s ease-in-out infinite;
	}

	.cl-skel-wide {
		width: 70%;
	}

	.cl-skel-narrow {
		width: 40%;
		margin-top: 6px;
	}

	@keyframes cl-skel-pulse {
		0%,
		100% {
			opacity: 0.45;
		}
		50% {
			opacity: 0.85;
		}
	}

	@media (prefers-reduced-motion: reduce) {
		.cl-skel-line {
			animation: none;
		}
	}
</style>
