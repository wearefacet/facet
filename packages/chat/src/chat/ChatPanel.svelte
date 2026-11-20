<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '../messages.js';
	import ChatScroll from './ChatScroll.svelte';
	import ChatThread from './ChatThread.svelte';
	import ChatBubble from './ChatBubble.svelte';
	import ChatTurnPanel from './ChatTurnPanel.svelte';
	import ChatInput from './ChatInput.svelte';
	import ConversationList from './ConversationList.svelte';
	import UsageMeter from './UsageMeter.svelte';
	import MapPin from '@lucide/svelte/icons/map-pin';
	import MessageSquarePlus from '@lucide/svelte/icons/message-square-plus';
	import PanelLeftOpen from '@lucide/svelte/icons/panel-left-open';
	import { applyChunkToParts, appendTextPart, type AgentPart } from './tool-call-helpers.js';
	import { reconstructTurns } from './reconstruct-turns.js';
	import { HttpAssistantError } from '../driver/errors.js';
	import { runCatchup, DEFAULT_CATCHUP_OPTIONS } from '../driver/catchup.js';
	import type { AssistantDriver } from '../driver/AssistantDriver.js';
	import type { AssistantUsage, Conversation, Turn as TurnRow } from '../driver/types.js';
	import { RAIL_WIDTH_DEFAULT, RAIL_WIDTH_MAX, RAIL_WIDTH_MIN } from './assistantWindowState.js';

	/**
	 * Reusable chat core — the full body of the assistant surface:
	 * conversation rail, thread, composer, and the turn logic (`handleSend`,
	 * part accumulation, cancel).
	 *
	 * The package mounts it twice, on the same core:
	 * - `<facet-assistant-window>` (floating) — inside the draggable
	 *   `AssistantWindow` shell; open state persists.
	 * - `<facet-assistant>` (inline) — fills the host's container; the host
	 *   owns the layout.
	 *
	 * Both mounts scope to one app's assistant: `context` filters the rail
	 * (`{kind: 'app', app_id}`) and `createConversation` posts to the
	 * per-app create route through the driver. The backend owns everything
	 * else — model, prompt, tool set.
	 *
	 * A `403` from the create or stream route means the assistant is not
	 * available for this app (disabled, wrong role) — the panel renders a
	 * dedicated denial state and hides the composer. A spent budget (`429`)
	 * renders the budget notice on the turn, as on any other error.
	 *
	 * The rail width persists only when the host binds it
	 * (`bind:railWidth`); the bounds live in `assistantWindowState.ts` next
	 * to the storage keys.
	 */

	let {
		driver,
		/** Context filter each rail fetch is scoped to. For the app assistant:
		 * `{kind: 'app', app_id}`. */
		context = {},
		/** Creates a new conversation in the app assistant's own mode. */
		createConversation,
		/** Divider label at the top of the thread. */
		daymark = undefined,
		/** Static chip rendered above the composer (e.g. the app's name). */
		contextHint = '',
		/** Assistant header rendered once per agent turn. Empty hides the header. */
		agentName = '',
		/** Role tag next to the assistant name. */
		agentTag = '',
		/** Composer placeholder. */
		placeholder = m.assistant_input_placeholder(),
		/** Conversation-rail width, two-way bindable so the host can persist it. */
		railWidth = $bindable(RAIL_WIDTH_DEFAULT)
	}: {
		driver: AssistantDriver;
		context?: Record<string, unknown>;
		createConversation: () => Promise<Conversation>;
		daymark?: string;
		contextHint?: string;
		agentName?: string;
		agentTag?: string;
		placeholder?: string;
		railWidth?: number;
	} = $props();

	type Turn =
		| { id: number; kind: 'user'; content: string }
		| { id: number; kind: 'agent'; parts: AgentPart[]; streaming: boolean };

	let conversation = $state<Conversation | null>(null);
	let turns = $state<Turn[]>([]);

	/** Monotonic counter for stable turn keys. */
	let turnSeq = 0;
	let busy = $state(false);
	let error = $state<string | null>(null);
	let inputText = $state('');
	let currentTurnToken = $state<string | null>(null);
	/** Bump to force ConversationList to reload after a turn lands. */
	let listVersion = $state(0);
	/** When true, the conversation rail is hidden (mounted but display:none). */
	let convCollapsed = $state(false);
	/** Rolling-window usage meter data. `null` hides the meter — unlimited
	 * budget, or the usage fetch failed (never blocks the chat). */
	let usage = $state<AssistantUsage | null>(null);
	/** Set when the backend answers `403` on create or stream: the assistant
	 * is unavailable for this app. Renders the denial state and hides the
	 * composer; resets with the context. */
	let accessDenied = $state(false);

	// Reset when the context changes — each context (e.g. each app) carries
	// its own conversation set. The key comparison (not object identity)
	// decides, because hosts build a fresh context object on every render.
	// The guard ensures the reset fires only on a real change.
	// svelte-ignore state_referenced_locally — intentional initial seeding.
	let lastContextKey = JSON.stringify(context);
	$effect(() => {
		const key = JSON.stringify(context);
		if (key === lastContextKey) return;
		lastContextKey = key;
		conversation = null;
		turns = [];
		error = null;
		inputText = '';
		busy = false;
		accessDenied = false;
	});

	// Usage meter: fetched once on mount, in the background — the chat never
	// waits for it, and a failure just leaves the meter hidden.
	$effect(() => {
		driver
			.getUsage()
			.then((u: AssistantUsage) => (usage = u))
			.catch(() => (usage = null));
	});

	/** True when an error is the assistant-unavailable denial (403). */
	function isAccessDenied(err: unknown): boolean {
		return err instanceof HttpAssistantError && err.status === 403;
	}

	async function handleSelect(selected: Conversation) {
		if (busy) return;
		conversation = selected;
		turns = [];
		error = null;
		try {
			const listed = await driver.listTurns(selected.id);
			turns = turnsFromRows(listed);
		} catch (err) {
			error = m.assistant_turns_load_failed({ message: (err as Error).message });
		}
	}

	/**
	 * Maps persisted server turn rows onto the UI turn list. A terminal
	 * `error` or `capped` turn renders the user bubble, the partial
	 * exchange, plus a plain error segment, matching the live-stream
	 * `> Error:` rendering. A capped row keeps the partial exchange — the
	 * tool-call loop hit the agent's iteration cap — and replays it on the
	 * next turn.
	 *
	 * A `running` row renders its checkpointed partial exchange (the backend
	 * writes completed iterations into the row while it generates) above a
	 * live thinking placeholder, so a surface that loads the history
	 * mid-generation shows the same picture the live stream would. Exactly
	 * one row can run per conversation, and it is always the latest.
	 */
	function turnsFromRows(rows: TurnRow[]): Turn[] {
		return rows.flatMap((row) => {
			if (row.status === 'running') {
				const user = reconstructTurns(row.request_messages, row.response_messages, false).map(
					(ut) => ({
						...ut,
						id: ++turnSeq
					})
				) as Turn[];
				user.push({ id: ++turnSeq, kind: 'agent', parts: [], streaming: true });
				return user;
			}
			const base = reconstructTurns(
				row.request_messages,
				row.response_messages,
				row.status === 'cancelled'
			).map((ut) => ({
				...ut,
				id: ++turnSeq
			})) as Turn[];
			if (row.status === 'error' || row.status === 'capped') {
				base.push({
					id: ++turnSeq,
					kind: 'agent',
					parts: [
						{
							type: 'text',
							content: m.assistant_error_line({
								message: row.error ?? m.assistant_turn_failed()
							})
						}
					],
					streaming: false
				});
			}
			return base;
		});
	}

	async function handleNew() {
		if (busy) return;
		try {
			conversation = await createConversation();
			turns = [];
			error = null;
			listVersion++;
		} catch (err) {
			if (isAccessDenied(err)) {
				accessDenied = true;
				error = null;
				return;
			}
			error = m.assistant_conversation_create_failed({ message: (err as Error).message });
		}
	}

	async function handleSend(text: string) {
		if (busy) return;

		// If no conversation exists yet, create one and attach this message to
		// it instead of silently dropping the input.
		if (!conversation) {
			await handleNew();
			if (!conversation) return; // creation failed — the denial or error already surfaced
		}

		error = null;
		turns = [...turns, { id: ++turnSeq, kind: 'user', content: text }];
		busy = true;

		const agentTurn: Turn = { id: ++turnSeq, kind: 'agent', parts: [], streaming: true };
		turns = [...turns, agentTurn];
		const idx = turns.length - 1;

		let parts: AgentPart[] = [];
		let streaming = true;

		const convId = conversation.id;

		// Set when the iterator ends WITHOUT a terminal SSE event — the fetch
		// body broke (refresh, network switch, provider mid-stream failure).
		// The turn may still be running server-side.
		let brokeWithoutTerminal = false;

		try {
			brokeWithoutTerminal = true; // flipped off by each terminal event
			for await (const ev of driver.streamAsk(convId, { content: text })) {
				if (ev.event === 'meta') {
					currentTurnToken = ev.turn_token;
				} else if (ev.event === 'chunk') {
					parts = applyChunkToParts(parts, ev.chunk);
				} else if (ev.event === 'done') {
					brokeWithoutTerminal = false;
					streaming = false;
				} else if (ev.event === 'error') {
					brokeWithoutTerminal = false;
					parts = appendTextPart(parts, `\n\n${m.assistant_error_line({ message: ev.message })}`);
					streaming = false;
				} else if (ev.event === 'cancelled') {
					brokeWithoutTerminal = false;
					parts = appendTextPart(parts, `\n\n${m.assistant_cancelled_note()}`);
					streaming = false;
				}
				turns = turns.map((t, i) =>
					i === idx && t.kind === 'agent' ? { ...t, parts, streaming } : t
				);
			}
		} catch (err) {
			if (isAccessDenied(err)) {
				// The gate re-checks access per message — a mid-session disable
				// lands here. Drop the empty agent turn and show the denial state.
				accessDenied = true;
				error = null;
				turns = turns.filter((t, i) => !(i === idx && t.kind === 'agent' && t.parts.length === 0));
				return;
			}
			// A spent budget is expected and self-explanatory — show the dedicated
			// line instead of the bare status text.
			const message =
				err instanceof HttpAssistantError && err.status === 429
					? m.assistant_usage_limit_reached()
					: (err as Error).message;
			parts = appendTextPart(parts, `\n\n${m.assistant_error_line({ message })}`);
			streaming = false;
			turns = turns.map((t, i) =>
				i === idx && t.kind === 'agent' ? { ...t, parts, streaming } : t
			);
		} finally {
			// The fetch body broke mid-turn (refresh, network switch). The
			// backend keeps generating — poll the turn state and, once the
			// orphaned turn settles, rebuild the thread from server truth so
			// the user keeps the reply they would otherwise have lost. A normal
			// `done` / `error` / `cancelled` event means the exit path already
			// ran; no catch-up is needed. `busy` stays true for the whole
			// catch-up: a send into this conversation would 409 anyway.
			if (brokeWithoutTerminal) {
				try {
					// Turns before the [user bubble, placeholder] pair appended
					// above — the suffix a tick replaces with server truth.
					const baseLen = turns.length - 2;
					// Id of the trailing streaming placeholder. Re-read after each
					// rebuild — a rebuild replaces the tail, so the original id
					// goes stale.
					let placeholderId = agentTurn.id;
					const outcome = await runCatchup(
						() => driver.latestTurn(convId),
						(ms) => new Promise((r) => setTimeout(r, ms)),
						{
							...DEFAULT_CATCHUP_OPTIONS,
							// Progressive rebuild: while the turn runs, render the
							// checkpointed partial from server truth instead of
							// waiting for the settle.
							onTick: (summary) => {
								const row: TurnRow = {
									id: summary.id,
									conversation_id: convId,
									idx: summary.idx,
									request_messages: summary.request_messages,
									response_messages: summary.response_messages,
									status: 'running',
									usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 },
									finish_reason: null,
									error: null,
									created_at: summary.created_at
								};
								const rebuilt = turnsFromRows([row]);
								turns = [...turns.slice(0, baseLen), ...rebuilt];
								const tail = rebuilt[rebuilt.length - 1];
								if (tail) placeholderId = tail.id;
							}
						}
					);
					if (outcome.outcome === 'settled' || outcome.outcome === 'timeout') {
						try {
							const listed = await driver.listTurns(convId);
							turns = turnsFromRows(listed);
						} catch {
							// Server refetch failed — the partial text + error note above stand.
						}
					}
					if (outcome.outcome === 'timeout') {
						// Budget spent while still running — mark the current
						// placeholder (a tick rebuild may have replaced the original
						// one) and stop its caret.
						turns = turns.map((t) =>
							t.id === placeholderId && t.kind === 'agent'
								? {
										...t,
										parts: appendTextPart(t.parts, `\n\n${m.assistant_still_generating()}`),
										streaming: false
									}
								: t
						);
					}
					// `no_turn` — nothing was ever opened; keep the local error state.
				} catch {
					// The status endpoint itself failed (offline, 5xx) — keep the
					// local error state; a reload catches up through listTurns.
				}
			}
			busy = false;
			currentTurnToken = null;
			listVersion++;
		}
	}

	async function handleCancel() {
		if (!currentTurnToken) return;
		try {
			await driver.cancel(currentTurnToken);
		} catch {
			/* cancel signal may already be cleaned up — ignore */
		}
	}

	// ── Conversation rail width (user-resizable) ────────────────────────────
	//
	// The right edge of the rail is a drag handle. The width lives in the
	// two-way `railWidth` prop, so the host decides whether it persists.
	let railDragging = $state(false);

	function onRailDragStart(e: PointerEvent) {
		railDragging = true;
		(e.currentTarget as HTMLElement).setPointerCapture(e.pointerId);
		// Floating shells also drag from their header — keep the pointer for
		// ourselves so the window never moves with the rail.
		e.stopPropagation();
	}

	function onRailDragMove(e: PointerEvent) {
		if (!railDragging) return;
		// The rail grows to the right; its width = pointer x - rail left edge.
		const railEl = (e.currentTarget as HTMLElement).parentElement;
		if (!railEl) return;
		const rect = railEl.getBoundingClientRect();
		const next = e.clientX - rect.left;
		railWidth = Math.max(RAIL_WIDTH_MIN, Math.min(RAIL_WIDTH_MAX, next));
	}

	function onRailDragEnd(e: PointerEvent) {
		if (!railDragging) return;
		railDragging = false;
		(e.currentTarget as HTMLElement).releasePointerCapture(e.pointerId);
	}
</script>

<div class="chat-panel" class:rail-dragging={railDragging}>
	{#if error}
		<div class="banner">
			<span>{error}</span>
			<button class="dismiss" onclick={() => (error = null)}>{m.assistant_dismiss()}</button>
		</div>
	{/if}

	<div class="panel-body">
		{#if convCollapsed}
			<!-- Collapsed rail: thin always-visible edge so the user can re-expand. -->
			<button
				class="rail-expand-edge"
				type="button"
				onclick={() => (convCollapsed = false)}
				aria-label={m.assistant_conversations_show()}
				aria-pressed={false}
				title={m.assistant_conversations_show()}
			>
				<PanelLeftOpen size={14} stroke-width={1.9} />
			</button>
		{:else}
			<div class="conv-rail" style:width="{railWidth}px">
				<ConversationList
					{driver}
					context={{ ...context }}
					pageSize={30}
					reloadKey={listVersion}
					selectedId={conversation?.id}
					onselect={handleSelect}
					onnew={handleNew}
					oncollapse={() => (convCollapsed = true)}
				/>
				<!-- Resize handle on the rail's right edge. stopPropagation on
				  pointerdown so a floating host's drag handler never also engages. -->
				<div
					class="rail-resizer"
					role="separator"
					aria-orientation="vertical"
					aria-label={m.assistant_rail_resize_aria()}
					onpointerdown={onRailDragStart}
					onpointermove={onRailDragMove}
					onpointerup={onRailDragEnd}
					onpointercancel={onRailDragEnd}
				></div>
			</div>
		{/if}

		<div class="chat-shell">
			<ChatScroll>
				<div class="thread-inner">
					<div class="thread-col">
						{#if accessDenied}
							<div class="denied" role="alert">
								<p class="denied-title">{m.assistant_access_denied_title()}</p>
								<p class="denied-body">{m.assistant_access_denied_body()}</p>
							</div>
						{:else if !conversation}
							<div class="empty-hint">
								<p>{m.assistant_empty_hint()}</p>
								<button class="new-conv-btn" onclick={handleNew} disabled={busy}>
									<MessageSquarePlus size={14} stroke-width={1.9} />
									{m.assistant_new_conversation()}
								</button>
							</div>
						{:else}
							<ChatThread {daymark}>
								{#if turns.length === 0}
									<div class="empty-hint">{m.assistant_thread_empty()}</div>
								{/if}
								{#each turns as t (t.id)}
									{#if t.kind === 'user'}
										<ChatBubble role="user" content={t.content} />
									{:else}
										<ChatTurnPanel
											name={agentName}
											tag={agentTag}
											parts={t.parts}
											streaming={t.streaming}
											streamActive={t.streaming}
										/>
									{/if}
								{/each}
							</ChatThread>
						{/if}
					</div>
				</div>
			</ChatScroll>
			{#if !accessDenied}
				<div class="composer-bar">
					{#if usage && usage.budget !== null}
						<UsageMeter used={usage.total} budget={usage.budget} windowDays={usage.window_days} />
					{/if}
					{#if contextHint}
						<div class="context-chip">
							<MapPin size={12} stroke-width={1.9} />
							<span>{contextHint}</span>
						</div>
					{/if}
					<ChatInput
						bind:value={inputText}
						{placeholder}
						{busy}
						onsend={handleSend}
						onstop={handleCancel}
					/>
				</div>
			{/if}
		</div>
	</div>
</div>

<style>
	.chat-panel {
		flex: 1;
		display: flex;
		flex-direction: column;
		min-height: 0;
		min-width: 0;
		overflow: hidden;
	}

	.chat-panel.rail-dragging {
		user-select: none;
		cursor: col-resize;
	}

	.banner {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 8px;
		padding: 6px 12px;
		background: var(--facet-danger-weak, #fde8e8);
		color: var(--facet-danger, #c0392b);
		font-size: 12px;
		flex-shrink: 0;
	}

	.dismiss {
		border: 1px solid currentColor;
		background: transparent;
		color: inherit;
		border-radius: 4px;
		padding: 2px 8px;
		font-size: 11px;
		cursor: pointer;
		white-space: nowrap;
	}

	.panel-body {
		flex: 1;
		display: flex;
		min-height: 0;
		overflow: hidden;
	}

	.conv-rail {
		position: relative;
		flex-shrink: 0;
		min-height: 0;
		border-right: 1px solid var(--facet-border);
		overflow: hidden;
	}

	.chat-shell {
		flex: 1;
		display: flex;
		flex-direction: column;
		min-width: 0;
		min-height: 0;
	}

	.thread-inner {
		padding: 14px;
	}

	/* Constrain the conversation body so bubbles/code don't stretch edge to
	   edge on wide surfaces. Centered with auto margins. */
	.thread-col {
		max-width: 900px;
		margin: 0 auto;
		width: 100%;
		min-width: 0;
	}

	.empty-hint {
		color: var(--facet-text-3);
		font-size: 12.5px;
		display: flex;
		flex-direction: column;
		align-items: flex-start;
		gap: 10px;
	}

	.new-conv-btn {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		padding: 6px 11px;
		border: 1px solid var(--facet-border);
		border-radius: var(--facet-r-sm);
		background: var(--facet-surface);
		color: var(--facet-text-2);
		font-size: 12px;
		cursor: pointer;
		transition:
			border-color 0.12s ease,
			color 0.12s ease;
	}

	.new-conv-btn:hover:not(:disabled) {
		border-color: var(--facet-accent);
		color: var(--facet-text);
	}

	.new-conv-btn:disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}

	/* ── Access denied — the clean 403 empty state ─────────────────────── */
	.denied {
		display: flex;
		flex-direction: column;
		gap: 6px;
		padding: 16px;
		border: 1px solid var(--facet-border);
		border-radius: var(--facet-r);
		background: var(--facet-surface);
		max-width: 420px;
	}

	.denied-title {
		margin: 0;
		font-family: var(--facet-font-display);
		font-size: 13.5px;
		font-weight: 600;
		color: var(--facet-text);
	}

	.denied-body {
		margin: 0;
		font-size: 12.5px;
		line-height: 1.5;
		color: var(--facet-text-2);
	}

	.composer-bar {
		padding: 8px 12px 12px;
		border-top: 1px solid var(--facet-border);
		display: flex;
		flex-direction: column;
		gap: 6px;
	}

	/* Space the usage meter from the input below (the child owns its own styles). */
	.composer-bar :global(.usage-meter) {
		margin-bottom: 6px;
	}

	.context-chip {
		display: inline-flex;
		align-items: center;
		gap: 5px;
		font-family: var(--facet-font-mono);
		font-size: 10px;
		color: var(--facet-text-3);
		background: var(--facet-sunken);
		padding: 3px 8px;
		border-radius: var(--facet-r-pill);
		width: fit-content;
		max-width: 100%;
		overflow: hidden;
	}

	.context-chip span {
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	/* ── Conversation rail: resize handle ────────────────────────────────── */
	.rail-resizer {
		position: absolute;
		top: 0;
		right: 0;
		width: 6px;
		height: 100%;
		cursor: col-resize;
		z-index: 2;
		/* Invisible until hover/focus so it doesn't clutter the rail border. */
		background: transparent;
		transition: background 0.12s ease;
	}
	.rail-resizer:hover,
	.rail-resizer:active,
	.rail-resizer:focus-visible {
		background: var(--facet-accent-weak);
	}
	.rail-resizer:focus-visible {
		outline: 2px solid var(--facet-accent);
		outline-offset: -2px;
	}

	/* Collapsed rail: a thin always-visible edge holding the expand button, so
	   the user can re-open the conversation list after collapsing it. */
	.rail-expand-edge {
		display: grid;
		place-items: center;
		width: 22px;
		flex-shrink: 0;
		min-height: 0;
		border-right: 1px solid var(--facet-border);
		background: var(--facet-surface-2, var(--facet-surface));
		color: var(--facet-text-3);
		cursor: pointer;
		padding: 0;
		border-top: none;
		border-bottom: none;
		border-left: none;
		transition:
			background 0.12s ease,
			color 0.12s ease;
	}
	.rail-expand-edge:hover {
		background: var(--facet-accent-weak);
		color: var(--facet-accent-ink);
	}
	.rail-expand-edge:focus-visible {
		outline: 2px solid var(--facet-accent);
		outline-offset: -2px;
	}
</style>
