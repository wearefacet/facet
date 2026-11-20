<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import ChatScroll from './ChatScroll.svelte';
	import ChatThread from './ChatThread.svelte';
	import ChatBubble from './ChatBubble.svelte';
	import ChatTurnPanel from './ChatTurnPanel.svelte';
	import ChatInput from './ChatInput.svelte';
	import ConversationList from './ConversationList.svelte';
	import UsageMeter from './UsageMeter.svelte';
	import { MapPin, MessageSquarePlus, PanelLeftOpen } from '@lucide/svelte';
	import { DocumentDataDriver } from '$lib/datasource/DocumentDriver.js';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import {
		applyChunkToParts,
		appendTextPart,
		HttpAssistantError,
		isNavigateChunk,
		isWorkspaceNavigateChunk,
		parseGoToPage,
		parseNavigateTarget,
		reconstructTurns,
		runCatchup,
		type AgentPart,
		type AssistantDriver,
		type AssistantUsage,
		type Conversation,
		type GoToPageArgs,
		type NavigateTargetArgs,
		type StreamChunk,
		type Turn as TurnRow
	} from '$lib/assistant/index.js';
	import {
		RAIL_WIDTH_DEFAULT,
		RAIL_WIDTH_MAX,
		RAIL_WIDTH_MIN
	} from '$lib/components/features/chat/assistantWindowState.js';

	/**
	 * Reusable chat core — the full body of an assistant surface: conversation
	 * rail, thread, composer, and the turn logic (`handleSend`, part
	 * accumulation, UI-tool chunk handling, cancel).
	 *
	 * One component, two mounts — each inside the same floating-window shell
	 * (`AssistantWindow.svelte`, also in `features/chat/`):
	 * - `FloatingAssistant.svelte` (builder) — the draft-scoped window;
	 *   page context comes from the builder URL, navigation goes back into
	 *   the builder.
	 * - `WorkspaceAssistant.svelte` (main application) — the account-scoped
	 *   window; the list filters to the account's own workspace
	 *   conversations.
	 *
	 * Mode-specific behaviour is injected through props:
	 * - `context` scopes the conversation rail. When it changes, the panel
	 *   resets — each context carries its own conversation set.
	 * - `createConversation` is the conversation factory for the new action.
	 * - `pageContext` returns the `[Page context: …]` prefix sent above each
	 *   message. Leave it out on surfaces with no page awareness.
	 * - `navigate` runs the `go_to_page` UI tool on the live stream, and
	 *   `navigateWorkspace` the workspace `navigate` tool. Only live chunks
	 *   reach them — replayed turns go through `reconstructTurns`, so history
	 *   never re-navigates.
	 * - `documentDriver` feeds the workspace surfaces (document rows and
	 *   cards). It defaults to the HTTP driver against the app origin;
	 *   stories inject a mock.
	 *
	 * The rail width persists only when the host binds it
	 * (`bind:railWidth`); the bounds live in `assistantWindowState.ts` next
	 * to the storage key.
	 */

	let {
		driver,
		/** Context filter each rail fetch is scoped to, e.g.
		 * `{kind: 'workspace', created_by}` or `{kind: 'domain-builder', draft_domain}`. */
		context = {},
		/** Creates a new conversation in the surface's own mode. */
		createConversation,
		/** Returns the `[Page context: …]` prefix sent above each message. */
		pageContext = undefined,
		/** Executes the `go_to_page` UI tool on the live stream. */
		navigate = undefined,
		/** Executes the workspace `navigate` UI tool on the live stream. */
		navigateWorkspace = undefined,
		/** Data driver for the workspace surfaces (document rows and cards). */
		documentDriver = new DocumentDataDriver(''),
		/** Divider label at the top of the thread. */
		daymark = undefined,
		/** Static chip rendered above the composer (e.g. "crm · Customer"). */
		contextHint = '',
		/** Assistant header rendered once per agent turn. Empty hides the header. */
		agentName = '',
		/** Role tag next to the assistant name. */
		agentTag = '',
		/** Composer placeholder. */
		placeholder = m.assistant_input_placeholder(),
		/** Whether an AI provider is configured for the installation. `false`
		 * keeps the window (and any history) browsable but disables new
		 * conversations and the composer, with an explanatory message. */
		configured = true,
		/** Conversation-rail width, two-way bindable so the host can persist it. */
		railWidth = $bindable(RAIL_WIDTH_DEFAULT)
	}: {
		driver: AssistantDriver;
		context?: Record<string, unknown>;
		createConversation: () => Promise<Conversation>;
		pageContext?: () => string;
		navigate?: (args: GoToPageArgs) => void;
		navigateWorkspace?: (target: NavigateTargetArgs) => void;
		documentDriver?: DataDriver;
		daymark?: string;
		contextHint?: string;
		agentName?: string;
		agentTag?: string;
		placeholder?: string;
		/** Whether an AI provider is configured for the installation. */
		configured?: boolean;
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
	/** True while this panel is attached to a live SSE stream (`handleSend`).
	 * A stream writes its chunks into `turns` by index, so switching
	 * conversations mid-stream would corrupt the other thread — navigation
	 * stays blocked until the stream (and its broken-stream watch) ends. An
	 * orphan watch (reload path) does NOT set this: it only polls server-side
	 * state, so the rail stays navigable while it runs. */
	let streaming = $state(false);
	/** Generation counter for conversation selections — a `listTurns`
	 * response that belongs to an older selection is discarded. */
	let selectSeq = 0;
	/** Generation counter for orphan watches — bumping it cancels the
	 * in-flight watch: it stops polling and writes nothing. */
	let watchToken = 0;
	let error = $state<string | null>(null);
	let inputText = $state('');
	/** Unconfigured posture: no provider resolves for this installation. The
	 * window stays open and history stays readable, but nothing may create a
	 * conversation or send a turn — the message explains the posture and
	 * names the fix (system settings). */
	let unconfigured = $derived(!configured);
	let currentTurnToken = $state<string | null>(null);
	/** True once the stop action posted a cancel for the in-flight turn. The
	 *  stream can then die at the transport level before the `cancelled`
	 *  frame arrives — the failure renders the cancelled note instead of a
	 *  raw browser error, because the turn settles as cancelled server-side
	 *  either way. Reset on each new send. */
	let cancelIntentSent = false;
	/** Bump to force ConversationList to reload after a turn lands. */
	let listVersion = $state(0);
	/** When true, the conversation rail is hidden (mounted but display:none). */
	let convCollapsed = $state(false);
	/** Rolling-window usage meter data. `null` hides the meter — unlimited
	 * budget, or the usage fetch failed (never blocks the chat). */
	let usage = $state<AssistantUsage | null>(null);

	// Reset when the context changes — each context (e.g. each builder draft)
	// carries its own conversation set. The key comparison (not object
	// identity) decides, because hosts build a fresh context object on every
	// render. The guard ensures the reset fires only on a real change.
	// svelte-ignore state_referenced_locally — intentional initial seeding.
	let lastContextKey = JSON.stringify(context);
	$effect(() => {
		const key = JSON.stringify(context);
		if (key === lastContextKey) return;
		lastContextKey = key;
		cancelWatch();
		conversation = null;
		turns = [];
		error = null;
		inputText = '';
		busy = false;
		currentTurnToken = null;
	});

	/** Cancels the in-flight orphan watch, if any. The superseded watch's
	 * `finally` sees the token mismatch and leaves the panel flags alone —
	 * the caller owns them from here. */
	function cancelWatch(): void {
		watchToken++;
	}

	// Usage meter: fetched once on mount, in the background — the chat never
	// waits for it, and a failure just leaves the meter hidden.
	$effect(() => {
		driver
			.getUsage()
			.then((u) => (usage = u))
			.catch(() => (usage = null));
	});

	async function handleSelect(selected: Conversation) {
		// A live stream writes its chunks into `turns` by index — switching
		// conversations mid-stream would corrupt the other thread. An orphan
		// watch is safe to walk away from: selecting another conversation
		// cancels it (the backend's one-running-turn 409 applies to the
		// conversation that is generating, never to the panel).
		if (streaming) return;
		// Re-clicking the selected row is a no-op — the thread is already on
		// screen, and a watch, if any, keeps running.
		if (selected.id === conversation?.id) return;

		// Anything in flight belongs to the previous selection: cancel its
		// watch and release its composer lock before loading the new one.
		cancelWatch();
		busy = false;
		currentTurnToken = null;

		// Rapid row clicks resolve out of order — a `listTurns` response that
		// belongs to an older selection is discarded.
		const seq = ++selectSeq;
		conversation = selected;
		turns = [];
		error = null;
		try {
			const listed = await driver.listTurns(selected.id);
			if (seq !== selectSeq) return;
			turns = turnsFromRows(listed);

			// A running row means the backend is generating right now — this
			// device was not attached to its stream (page reload, another
			// device). The persisted user input plus the live thinking
			// placeholder already sit in `turns` (turnsFromRows emitted them);
			// lock the composer and watch the turn. The row carries the cancel
			// token, so the stop button works against the in-flight turn.
			const running = listed.find((row) => row.status === 'running');
			const placeholder = turns.find((t) => t.kind === 'agent' && t.streaming);
			if (running && placeholder && placeholder.kind === 'agent') {
				busy = true;
				currentTurnToken = running.turn_token ?? null;
				// Turns before the running row's block — the suffix the catch-up
				// tick replaces with server truth.
				const baseLen = turnsFromRows(listed.slice(0, listed.indexOf(running))).length;
				void watchOrphanedTurn(selected.id, placeholder.id, baseLen);
			}
		} catch (err) {
			if (seq !== selectSeq) return;
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
		if (streaming || unconfigured) return;
		cancelWatch();
		busy = false;
		currentTurnToken = null;
		try {
			conversation = await createConversation();
			turns = [];
			error = null;
			listVersion++;
		} catch (err) {
			error = m.assistant_conversation_create_failed({ message: (err as Error).message });
		}
	}

	/**
	 * Watches an orphaned running turn — one this surface is not consuming
	 * a stream for — until the backend settles it, then rebuilds the thread
	 * from server truth. Two callers:
	 *
	 * - `handleSelect`, when the loaded history contains a `running` row
	 *   (page reload or another device while the backend keeps generating);
	 * - `handleSend`, when the SSE body broke mid-turn (network switch, tab
	 *   frozen long enough to drop the socket).
	 *
	 * Polls `latestTurn` on the catch-up cadence. Each poll that finds the
	 * turn still running rebuilds the running block from the summary's
	 * messages, so the checkpointed partial exchange grows on screen while
	 * the backend generates. On `settled` the row is terminal, so the
	 * refetch renders the full reply, trace, and cancel / error markers. On
	 * any other outcome (timeout budget spent, status endpoint unreachable)
	 * the note turn keeps its partial content and gets the
	 * still-generating marker — honest about the ambiguity, and a reopen of
	 * the conversation catches up through `listTurns`.
	 *
	 * `noteTurnId` is the stable id of the agent turn carrying the partial
	 * state: the local streaming turn for `handleSend`, the placeholder turn
	 * for `handleSelect`. The running row's rendering is a contiguous
	 * suffix of `turns`; `baseLen` is the number of turns before that
	 * suffix, so each rebuild replaces exactly the running block. A rebuild
	 * replaces the trailing placeholder, so the still-generating marker
	 * targets the current placeholder id — the original note turn id goes
	 * stale after the first rebuild. Selecting another conversation (or a
	 * context reset) bumps the watch token: this watch stops polling and
	 * its `finally` leaves the panel flags to the newer owner.
	 */
	async function watchOrphanedTurn(
		convId: string,
		noteTurnId: number,
		baseLen: number
	): Promise<void> {
		const token = ++watchToken;
		// Id of the trailing streaming placeholder. Re-read after each rebuild
		// — a rebuild replaces the tail, so the original id goes stale.
		let placeholderId = noteTurnId;
		try {
			const outcome = await runCatchup(
				() => driver.latestTurn(convId),
				(ms) => new Promise((r) => setTimeout(r, ms)),
				{
					stop: () => token !== watchToken,
					// Progressive rebuild: while the turn runs, render the
					// checkpointed partial from server truth instead of waiting
					// for the settle.
					onTick: (summary) => {
						if (token !== watchToken) return;
						if (conversation?.id !== convId) return;
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
							turn_token: null,
							created_at: summary.created_at
						};
						const rebuilt = turnsFromRows([row]);
						turns = [...turns.slice(0, baseLen), ...rebuilt];
						const tail = rebuilt[rebuilt.length - 1];
						if (tail) placeholderId = tail.id;
					}
				}
			);
			// Superseded — a newer selection or a context reset owns the panel
			// now; this watch writes nothing.
			if (token !== watchToken) return;
			// The panel moved on without a new watch owner (context reset).
			if (conversation?.id !== convId) return;

			if (outcome.outcome === 'cancelled') return;
			if (outcome.outcome === 'settled') {
				try {
					const listed = await driver.listTurns(convId);
					turns = turnsFromRows(listed);
				} catch {
					// Refetch failed — the note turn's current state stands; a
					// reopen of the conversation catches up through listTurns.
					attachStillGenerating(placeholderId);
				}
			} else {
				// Timeout, or the status endpoint itself failed (offline, 5xx).
				attachStillGenerating(placeholderId);
			}
			// `no_turn` — the backend has no turns at all; the same note applies
			// (nothing was ever going to arrive on this conversation).
		} catch {
			// The status endpoint itself failed (offline, 5xx) mid-poll. The
			// turn may still be running — the note turn keeps its partial state
			// plus the marker; a reopen of the conversation catches up.
			if (token !== watchToken) return;
			if (conversation?.id !== convId) return;
			attachStillGenerating(placeholderId);
		} finally {
			// Only the owning watch releases the flags — a superseded one
			// would clobber the state of the selection that replaced it.
			if (token === watchToken) {
				busy = false;
				currentTurnToken = null;
				listVersion++;
			}
		}
	}

	/** Appends the still-generating marker to the agent turn carrying the
	 * orphaned turn's partial state, and stops its caret. */
	function attachStillGenerating(turnId: number): void {
		turns = turns.map((t) =>
			t.id === turnId && t.kind === 'agent'
				? {
						...t,
						parts: appendTextPart(t.parts, `\n\n${m.assistant_still_generating()}`),
						streaming: false
					}
				: t
		);
	}

	async function handleSend(text: string) {
		if (busy || unconfigured) return;

		// If no conversation exists yet, create one and attach this message to
		// it instead of silently dropping the input.
		if (!conversation) {
			await handleNew();
			if (!conversation) return; // creation failed — error already surfaced
		}

		error = null;
		cancelIntentSent = false;
		turns = [...turns, { id: ++turnSeq, kind: 'user', content: text }];
		busy = true;
		streaming = true;

		const agentTurn: Turn = { id: ++turnSeq, kind: 'agent', parts: [], streaming: true };
		turns = [...turns, agentTurn];
		const idx = turns.length - 1;

		let parts: AgentPart[] = [];
		let turnStreaming = true;

		const convId = conversation.id;

		const ctxPrefix = pageContext?.() ?? '';
		const apiContent = ctxPrefix ? `${ctxPrefix}\n\n${text}` : text;

		// Turns before the [user bubble, placeholder] pair appended above — the
		// suffix a catch-up tick replaces with server truth.
		const baseLen = turns.length - 2;

		// Set when the iterator ends WITHOUT a terminal SSE event — the fetch
		// body broke (refresh, network switch, provider mid-stream failure).
		// The turn may still be running server-side.
		let brokeWithoutTerminal = false;

		try {
			brokeWithoutTerminal = true; // flipped off by each terminal event
			for await (const ev of driver.streamAsk(convId, { content: apiContent })) {
				if (ev.event === 'meta') {
					currentTurnToken = ev.turn_token;
				} else if (ev.event === 'chunk') {
					parts = applyChunkToParts(parts, ev.chunk);
					handleUiToolChunk(ev.chunk);
				} else if (ev.event === 'done') {
					brokeWithoutTerminal = false;
					turnStreaming = false;
				} else if (ev.event === 'error') {
					brokeWithoutTerminal = false;
					parts = appendTextPart(parts, `\n\n${m.assistant_error_line({ message: ev.message })}`);
					turnStreaming = false;
				} else if (ev.event === 'cancelled') {
					brokeWithoutTerminal = false;
					parts = appendTextPart(parts, `\n\n${m.assistant_cancelled_note()}`);
					turnStreaming = false;
				}
				turns = turns.map((t, i) =>
					i === idx && t.kind === 'agent' ? { ...t, parts, streaming: turnStreaming } : t
				);
			}
		} catch (err) {
			if (cancelIntentSent) {
				// The stop action is already out and the stream body died before
				// the `cancelled` frame could arrive — a transport-level failure
				// after a cancel intent. The turn settles as cancelled server-side
				// (the broken-stream watch below rebuilds the thread from server
				// truth), so render the cancelled note, not the raw error.
				parts = appendTextPart(parts, `\n\n${m.assistant_cancelled_note()}`);
			} else {
				// A spent budget is expected and self-explanatory — show the
				// dedicated line instead of the bare status text.
				const message =
					err instanceof HttpAssistantError && err.status === 429
						? m.assistant_usage_limit_reached()
						: (err as Error).message;
				parts = appendTextPart(parts, `\n\n${m.assistant_error_line({ message })}`);
			}
			turnStreaming = false;
			turns = turns.map((t, i) =>
				i === idx && t.kind === 'agent' ? { ...t, parts, streaming: turnStreaming } : t
			);
		} finally {
			// The fetch body broke mid-turn (refresh, network switch). The
			// backend keeps generating — watch the turn state and, once the
			// orphaned turn settles, rebuild the thread from server truth so
			// the user keeps the reply they would otherwise have lost. A normal
			// `done` / `error` / `cancelled` event means the exit path already
			// ran; no catch-up is needed. `busy` stays true for the whole
			// watch: a send into this conversation would 409 anyway.
			if (brokeWithoutTerminal) {
				await watchOrphanedTurn(convId, agentTurn.id, baseLen);
			}
			busy = false;
			currentTurnToken = null;
			listVersion++;
			// Released last: the broken-stream watch keeps navigation blocked
			// until it ends (its rebuild targets the thread by conversation id,
			// but the panel stays attached to this turn's partial state).
			streaming = false;
		}
	}

	async function handleCancel() {
		if (!currentTurnToken) return;
		// Record the intent before the POST: a transport-level stream failure
		// after this point renders the cancelled note — the turn settles as
		// cancelled server-side even when the frame never arrives.
		cancelIntentSent = true;
		try {
			await driver.cancel(currentTurnToken);
		} catch {
			/* cancel signal may already be cleaned up — ignore */
		}
	}

	/** Executes UI-tool side effects on live chunks — navigation, delegated
	 * to the host through the `navigate` / `navigateWorkspace` props. */
	function handleUiToolChunk(chunk: StreamChunk): void {
		if (isNavigateChunk(chunk)) {
			const args = parseGoToPage(chunk.arguments);
			if (args && navigate) navigate(args);
			return;
		}
		if (isWorkspaceNavigateChunk(chunk)) {
			const target = parseNavigateTarget(chunk.arguments);
			if (target && navigateWorkspace) navigateWorkspace(target);
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
					activeId={busy ? (conversation?.id ?? undefined) : undefined}
					newDisabled={unconfigured}
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
						{#if !conversation}
							<div class="empty-hint">
								{#if unconfigured}
									<p>{m.assistant_not_configured()}</p>
									<button
										class="new-conv-btn"
										onclick={handleNew}
										disabled={true}
										title={m.assistant_not_configured()}
									>
										<MessageSquarePlus size={14} stroke-width={1.9} />
										{m.assistant_new_conversation()}
									</button>
								{:else}
									<p>{m.assistant_empty_hint()}</p>
									<button class="new-conv-btn" onclick={handleNew} disabled={busy}>
										<MessageSquarePlus size={14} stroke-width={1.9} />
										{m.assistant_new_conversation()}
									</button>
								{/if}
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
											{documentDriver}
										/>
									{/if}
								{/each}
							</ChatThread>
						{/if}
					</div>
				</div>
			</ChatScroll>
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
					disabled={unconfigured}
					onsend={handleSend}
					onstop={handleCancel}
				/>
			</div>
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
		background: var(--danger-weak, #fde8e8);
		color: var(--danger, #c0392b);
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
		border-right: 1px solid var(--border);
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
		color: var(--text-3);
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
		border: 1px solid var(--border);
		border-radius: var(--r-sm);
		background: var(--surface);
		color: var(--text-2);
		font-size: 12px;
		cursor: pointer;
		transition:
			border-color 0.12s ease,
			color 0.12s ease;
	}

	.new-conv-btn:hover:not(:disabled) {
		border-color: var(--accent);
		color: var(--text);
	}

	.new-conv-btn:disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}

	.composer-bar {
		padding: 8px 12px 12px;
		border-top: 1px solid var(--border);
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
		font-family: var(--font-mono);
		font-size: 10px;
		color: var(--text-3);
		background: var(--sunken);
		padding: 3px 8px;
		border-radius: var(--r-pill);
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
		background: var(--accent-weak);
	}
	.rail-resizer:focus-visible {
		outline: 2px solid var(--accent);
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
		border-right: 1px solid var(--border);
		background: var(--surface-2, var(--surface));
		color: var(--text-3);
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
		background: var(--accent-weak);
		color: var(--accent-ink);
	}
	.rail-expand-edge:focus-visible {
		outline: 2px solid var(--accent);
		outline-offset: -2px;
	}
</style>
