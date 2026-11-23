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

	/**
	 * Live turn state of one conversation. Streams write their chunks into a
	 * per-conversation entry, never into a shared array — so selecting
	 * another conversation mid-stream cannot corrupt the other thread, and
	 * N conversations can generate in parallel.
	 */
	interface ConvSession {
		/** The thread as rendered — history rows plus the live exchange. */
		turns: Turn[];
		/** Accumulated parts of the live agent turn (streaming only). */
		parts: AgentPart[];
		/** True while a live SSE stream is attached to this conversation. */
		streaming: boolean;
		/** Turns before the live `[user, placeholder]` pair — the suffix a
		 * catch-up rebuild replaces with server truth. */
		baseLen: number;
		/** Local id of the live agent turn (streaming only). */
		agentTurnId: number;
		/** Server cancel token of the in-flight turn, when known. */
		turnToken: string | null;
		/** The stop action posted a cancel; a transport break renders the
		 * cancelled note instead of the raw error. */
		cancelIntent: boolean;
		/** Messages typed while the turn was generating, drained FIFO on
		 * settle. The backend's one-running-turn rule (409) makes any other
		 * policy impossible, so exactly one message drains per settle. */
		pending: string[];
	}

	let conversation = $state<Conversation | null>(null);
	/** Per-conversation live state. Read through the derived `turns`. */
	const sessions = new Map<string, ConvSession>();

	/** Monotonic counter for stable turn keys. */
	let turnSeq = 0;
	/** Bumped on every write into any session — drives the derived reads. */
	let sessionsVersion = $state(0);
	/** True while the SELECTED conversation is generating (live stream or an
	 * orphan watch) — the composer lock. Other conversations may generate in
	 * parallel; their streams keep filling their own sessions in the
	 * background and the rail stays navigable. */
	let busy = $state(false);
	/** Server cancel token of the in-flight turn on the selected
	 * conversation — the stop button. `null` when idle. */
	let currentTurnToken = $state<string | null>(null);
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
	/** Bump to force ConversationList to reload after a turn lands. */
	let listVersion = $state(0);
	/** When true, the conversation rail is hidden (mounted but display:none). */
	let convCollapsed = $state(false);
	/** Rolling-window usage meter data. `null` hides the meter — unlimited
	 * budget, or the usage fetch failed (never blocks the chat). */
	let usage = $state<AssistantUsage | null>(null);

	/** The thread of the selected conversation (empty when none selected).
	 *
	 * Reads `sessionsVersion` directly and copies the session's arrays: a
	 * derived downstream of another derived only re-runs when the upstream
	 * OUTPUT reference changes, and a plain property read on the session
	 * object is not tracked (see doc/frontend/workflow.md → deep property
	 * mutations on shared proxy objects). A fresh shallow copy per recompute
	 * keeps the each-blocks honest. */
	const turns = $derived.by<Turn[]>(() => {
		void sessionsVersion;
		const s = conversation ? sessions.get(conversation.id) : null;
		return s ? [...s.turns] : [];
	});
	/** Queued messages of the selected conversation, rendered as dimmed
	 * pending bubbles above the composer. Same copy rule as `turns`. */
	const pendingMessages = $derived.by<string[]>(() => {
		void sessionsVersion;
		const s = conversation ? sessions.get(conversation.id) : null;
		return s ? [...s.pending] : [];
	});

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
		sessions.clear();
		sessionsVersion++;
		conversation = null;
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

	/** The session record of a conversation, created empty on first touch. */
	function sessionOf(convId: string): ConvSession {
		let s = sessions.get(convId);
		if (!s) {
			s = {
				turns: [],
				parts: [],
				streaming: false,
				baseLen: 0,
				agentTurnId: 0,
				turnToken: null,
				cancelIntent: false,
				pending: []
			};
			sessions.set(convId, s);
		}
		return s;
	}

	/** Replaces one session's thread and marks the derived reads stale. */
	function setTurns(convId: string, next: Turn[]): void {
		sessionOf(convId).turns = next;
		sessionsVersion++;
	}

	/** Writes the streaming parts into the live agent turn of a session. */
	function patchAgentTurn(convId: string): void {
		const s = sessionOf(convId);
		s.turns = s.turns.map((t, i) =>
			i === s.baseLen + 1 && t.kind === 'agent'
				? { ...t, parts: s.parts, streaming: s.streaming }
				: t
		);
		sessionsVersion++;
	}

	/** Applies the settle of one conversation's in-flight turn: release its
	 * live-stream state, then drain one queued message (FIFO) back into the
	 * send path. The backend allows one running turn per conversation —
	 * the drain can only start here, when the previous turn is over. */
	function settleSession(convId: string): void {
		const s = sessionOf(convId);
		s.streaming = false;
		s.turnToken = null;
		s.cancelIntent = false;
		sessionsVersion++;
		if (conversation?.id === convId) {
			busy = false;
			currentTurnToken = null;
		}
		if (s.pending.length > 0) {
			const [next, ...rest] = s.pending;
			s.pending = rest;
			sessionsVersion++;
			// Re-enter the send path for the drained message. `runTurn`
			// re-locks the session synchronously before its first await.
			void runTurn(convId, next);
		}
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
		console.log('PROBE select', selected.id.slice(-6), 'same=', selected.id === conversation?.id, 'streaming=', sessions.get(selected.id)?.streaming, 'pending=', sessions.get(selected.id)?.pending.length);
		// Re-clicking the selected row is a no-op — the thread is already on
		// screen, and a watch, if any, keeps running.
		if (selected.id === conversation?.id) return;

		// Anything in flight belongs to the previous selection: cancel its
		// watch and release the composer lock before loading the new one.
		// A live stream on the other conversation keeps running — its chunks
		// fill that conversation's own session, so switching cannot corrupt
		// anything; re-selecting it finds the entry still live.
		cancelWatch();
		busy = false;
		currentTurnToken = null;

		// Rapid row clicks resolve out of order — a `listTurns` response that
		// belongs to an older selection is discarded.
		const seq = ++selectSeq;
		conversation = selected;
		error = null;
		const s = sessionOf(selected.id);

		// A live stream (or a queue already draining) owns this conversation's
		// thread — its entry is ahead of the server rows, and a refetch would
		// overwrite the running turn with stale history.
		if (s.streaming || s.pending.length > 0) {
			busy = true;
			currentTurnToken = s.turnToken;
			sessionsVersion++;
			return;
		}

		try {
			const listed = await driver.listTurns(selected.id);
			if (seq !== selectSeq) return;
			setTurns(selected.id, turnsFromRows(listed));

			// A running row means the backend is generating right now — this
			// device was not attached to its stream (page reload, another
			// device). The persisted user input plus the live thinking
			// placeholder already sit in the turns (turnsFromRows emitted them);
			// lock the composer and watch the turn. The row carries the cancel
			// token, so the stop button works against the in-flight turn.
			const running = listed.find((row) => row.status === 'running');
			console.log('PROBE select listed', listed.length, 'statuses=', listed.map((r) => r.status).join(','), 'running=', !!running, 'seqOk=', seq === selectSeq);
			const current = sessionOf(selected.id);
			const placeholder = current.turns.find((t) => t.kind === 'agent' && t.streaming);
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
		if (unconfigured) return;
		cancelWatch();
		busy = false;
		currentTurnToken = null;
		try {
			conversation = await createConversation();
			sessionOf(conversation.id); // seed the empty session
			sessionsVersion++;
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
	 * state: the local streaming turn for the send path, the placeholder turn
	 * for `handleSelect`. The running row's rendering is a contiguous
	 * suffix of the session's turns; `baseLen` is the number of turns before
	 * that suffix, so each rebuild replaces exactly the running block. A
	 * rebuild replaces the trailing placeholder, so the still-generating
	 * marker targets the current placeholder id — the original note turn id
	 * goes stale after the first rebuild. Selecting another conversation (or
	 * a context reset) bumps the watch token: this watch stops polling and
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
						// A cancel intent was already posted: the turn settles as
						// cancelled server-side, so the rebuild carries the cancelled
						// note — without this the progressive tick would wipe the note
						// the transport-break catch rendered, and the user would see
						// the turn keep "thinking" after pressing stop.
						const tailTurn = rebuilt[rebuilt.length - 1];
						if (sessionOf(convId).cancelIntent && tailTurn && tailTurn.kind === 'agent') {
							tailTurn.parts = appendTextPart(
								tailTurn.parts,
								`\n\n${m.assistant_cancelled_note()}`
							);
							tailTurn.streaming = false;
						}
						setTurns(convId, [...sessionOf(convId).turns.slice(0, baseLen), ...rebuilt]);
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
					setTurns(convId, turnsFromRows(listed));
				} catch {
					// Refetch failed — the note turn's current state stands; a
					// reopen of the conversation catches up through listTurns.
					attachStillGenerating(convId, placeholderId);
				}
			} else {
				// Timeout, or the status endpoint itself failed (offline, 5xx).
				attachStillGenerating(convId, placeholderId);
			}
		} catch {
			// The status endpoint itself failed (offline, 5xx) mid-poll. The
			// turn may still be running — the note turn keeps its partial state
			// plus the marker; a reopen of the conversation catches up.
			if (token !== watchToken) return;
			if (conversation?.id !== convId) return;
			attachStillGenerating(convId, placeholderId);
		} finally {
			// Only the owning watch releases the flags — a superseded one
			// would clobber the state of the selection that replaced it.
			if (token === watchToken) {
				settleSession(convId);
				listVersion++;
			}
		}
	}

	/** Appends the still-generating marker to the agent turn carrying the
	 * orphaned turn's partial state, and stops its caret. */
	function attachStillGenerating(convId: string, turnId: number): void {
		const s = sessionOf(convId);
		s.turns = s.turns.map((t) =>
			t.id === turnId && t.kind === 'agent'
				? {
						...t,
						parts: appendTextPart(t.parts, `\n\n${m.assistant_still_generating()}`),
						streaming: false
					}
				: t
		);
		sessionsVersion++;
	}

	/** The composer entry point: a message for the selected conversation.
	 * While that conversation generates, the message queues (FIFO) and
	 * drains automatically when the turn settles — the user can keep typing
	 * and sending without waiting. The backend allows one running turn per
	 * conversation (409 on a second), so the queue is the only way a send
	 * during a turn can succeed later. When no conversation exists yet, one
	 * is created first and the message attaches to it. */
	async function handleSend(text: string) {
		if (unconfigured) return;
		// If no conversation exists yet, create one and attach this message to
		// it instead of silently dropping the input.
		if (!conversation) {
			await handleNew();
			if (!conversation) return; // creation failed — error already surfaced
		}
		const s = sessionOf(conversation.id);
		if (busy || s.streaming) {
			s.pending = [...s.pending, text];
			sessionsVersion++;
			return;
		}
		await runTurn(conversation.id, text);
	}

	/** Runs one streamed turn on a conversation — the live half of the old
	 * `handleSend`. Assumes the conversation is idle; `handleSend` and the
	 * queue drain are the only callers, and both gate on the session state. */
	async function runTurn(convId: string, text: string): Promise<void> {
		const s = sessionOf(convId);

		error = null;
		s.cancelIntent = false;
		s.streaming = true;
		s.turns = [...s.turns, { id: ++turnSeq, kind: 'user', content: text }];
		const agentTurn: Turn = { id: ++turnSeq, kind: 'agent', parts: [], streaming: true };
		s.turns = [...s.turns, agentTurn];
		s.agentTurnId = agentTurn.id;
		s.parts = [];
		// Turns before the [user bubble, placeholder] pair appended above — the
		// suffix a catch-up tick replaces with server truth.
		s.baseLen = s.turns.length - 2;
		sessionsVersion++;
		if (conversation?.id === convId) {
			busy = true;
			currentTurnToken = null;
		}

		const ctxPrefix = pageContext?.() ?? '';
		const apiContent = ctxPrefix ? `${ctxPrefix}\n\n${text}` : text;

		// Set when the iterator ends WITHOUT a terminal SSE event — the fetch
		// body broke (refresh, network switch, provider mid-stream failure).
		// The turn may still be running server-side.
		let brokeWithoutTerminal = false;

		try {
			brokeWithoutTerminal = true; // flipped off by each terminal event
			for await (const ev of driver.streamAsk(convId, { content: apiContent })) {
				if (ev.event === 'meta') {
					s.turnToken = ev.turn_token;
					if (conversation?.id === convId) currentTurnToken = ev.turn_token;
				} else if (ev.event === 'chunk') {
					s.parts = applyChunkToParts(s.parts, ev.chunk);
					handleUiToolChunk(ev.chunk);
				} else if (ev.event === 'done') {
					brokeWithoutTerminal = false;
					s.streaming = false;
				} else if (ev.event === 'error') {
					brokeWithoutTerminal = false;
					s.parts = appendTextPart(
						s.parts,
						`\n\n${m.assistant_error_line({ message: ev.message })}`
					);
					s.streaming = false;
				} else if (ev.event === 'cancelled') {
					brokeWithoutTerminal = false;
					s.parts = appendTextPart(s.parts, `\n\n${m.assistant_cancelled_note()}`);
					s.streaming = false;
				}
				patchAgentTurn(convId);
			}
		} catch (err) {
			if (s.cancelIntent) {
				// The stop action is already out and the stream body died before
				// the `cancelled` frame could arrive — a transport-level failure
				// after a cancel intent. The turn settles as cancelled server-side
				// (the broken-stream watch below rebuilds the thread from server
				// truth), so render the cancelled note, not the raw error.
				s.parts = appendTextPart(s.parts, `\n\n${m.assistant_cancelled_note()}`);
			} else {
				// A spent budget is expected and self-explanatory — show the
				// dedicated line instead of the bare status text.
				const message =
					err instanceof HttpAssistantError && err.status === 429
						? m.assistant_usage_limit_reached()
						: (err as Error).message;
				s.parts = appendTextPart(s.parts, `\n\n${m.assistant_error_line({ message })}`);
			}
			s.streaming = false;
			patchAgentTurn(convId);
		} finally {
			// The fetch body broke mid-turn (refresh, network switch). The
			// backend keeps generating — watch the turn state and, once the
			// orphaned turn settles, rebuild the thread from server truth so
			// the user keeps the reply they would otherwise have lost. A normal
			// `done` / `error` / `cancelled` event means the exit path already
			// ran; no catch-up is needed. The session stays owned by the watch
			// until it ends: a send into this conversation would 409 anyway.
			if (brokeWithoutTerminal) {
				await watchOrphanedTurn(convId, s.agentTurnId, s.baseLen);
			} else {
				settleSession(convId);
			}
			listVersion++;
		}
	}

	async function handleCancel() {
		if (!currentTurnToken || !conversation) return;
		const s = sessionOf(conversation.id);
		// Record the intent before the POST: a transport-level stream failure
		// after this point renders the cancelled note — the turn settles as
		// cancelled server-side even when the frame never arrives.
		s.cancelIntent = true;
		// A deliberate stop also drops the queue: the user asked the agent to
		// stop working on this conversation, not to run the typed follow-ups.
		if (s.pending.length > 0) {
			s.pending = [];
			sessionsVersion++;
		}
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
								{#each pendingMessages as pending, i (i)}
									<ChatBubble role="user" content={pending} pending />
								{/each}
							</ChatThread>
						{/if}
					</div>
				</div>
			</ChatScroll>
			<div class="composer-bar">
				{#if usage && usage.budget !== null}
					<UsageMeter
						used={usage.total}
						estimated={usage.estimated_total ?? 0}
						budget={usage.budget}
						windowDays={usage.window_days}
					/>
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
					queueCount={pendingMessages.length}
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
