// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { AssistantDriver } from '../AssistantDriver.js';
import type {
	AssistantSseEvent,
	AssistantUsage,
	Conversation,
	CreateConversationInput,
	CreateDomainBuilderConversationInput,
	ListConversationsParams,
	ListConversationsResult,
	RecordTurnInput,
	StreamAskInput,
	Turn,
	TurnSummary
} from '../types.js';
import type { AssistantScript } from './scripts.js';
import { defaultScripts } from './scripts.js';
import { MockConversationStore, ulid } from './conversation.js';
import { MockTurnStore } from './turn.js';
import { MockStreamSession } from './session.js';

/**
 * Owner id the mock stamps on workspace conversations
 * (`context.created_by`). The real backend always uses the signed-in
 * account's id; the mock has no session, so stories filter the dock's
 * conversation list with this same constant.
 */
export const MOCK_WORKSPACE_ACCOUNT_ID = 'core.account_kara';

/**
 * In-memory `AssistantDriver` for Storybook and component tests.
 *
 * Mirrors `Assistant::Routes` + `Assistant::Stream::Session`: it composes a
 * {@link MockConversationStore}, a {@link MockTurnStore}, and a per-call
 * {@link MockStreamSession}. No network, no Redis — the cancel bus is an
 * in-memory `Set<turnToken>` that the live session polls between chunks.
 *
 * Scripts drive the streamed reply: the first script whose `match` predicate
 * returns `true` for the user's message is played. Callers can prepend their
 * own via {@link MockAssistantDriver.addScript}; the defaults cover the
 * "logistics" sample and the error / cancel paths used by the Chat stories.
 *
 * @example
 * ```ts
 * const driver = new MockAssistantDriver();
 * const conv = await driver.createConversation({
 *   session_id: 's-1', cache_key: 'k-1', model: 'gpt-4o'
 * });
 * for await (const ev of driver.streamAsk(conv.id, { content: 'design a logistics domain' })) {
 *   console.log(ev);
 * }
 * ```
 */
export class MockAssistantDriver implements AssistantDriver {
	private readonly conversations = new MockConversationStore();
	private readonly turns = new MockTurnStore(this.conversations);
	private readonly scripts: AssistantScript[];
	/** Active cancel tokens, mirroring the Redis cancel bus. */
	private readonly cancelTokens = new Set<string>();
	/** Active streaming sessions keyed by turn_token, for cancel routing. */
	private readonly activeSessions = new Map<string, MockStreamSession>();
	/** Usage-meter payload served by {@link getUsage}; pinned via the options bag. */
	private readonly usage: AssistantUsage;

	constructor(
		scripts: AssistantScript[] = defaultScripts,
		options: { usage?: AssistantUsage } = {}
	) {
		// Copy so callers can mutate via `addScript` without touching the shared defaults.
		this.scripts = [...scripts];
		// Unlimited by default — the meter stays hidden unless a story or test
		// pins a finite budget through the options bag.
		this.usage = options.usage ?? {
			total: 0,
			estimated_total: 0,
			budget: null,
			window_start: new Date(Date.now() - 30 * 86_400_000).toISOString(),
			window_days: 30
		};
	}

	/** Adds a script at the front of the list (highest priority). */
	addScript(script: AssistantScript): this {
		this.scripts.unshift(script);
		return this;
	}

	// ── Conversation routes ─────────────────────────────────────────────────

	createConversation(input: CreateConversationInput): Promise<Conversation> {
		return Promise.resolve(this.conversations.create(input));
	}

	createDomainBuilderConversation(
		input: CreateDomainBuilderConversationInput
	): Promise<Conversation> {
		return Promise.resolve(
			this.conversations.create({
				context: {
					kind: 'domain-builder',
					draft_domain: input.draft_domain ?? '_mock_draft',
					target_name: input.target_name,
					description: input.description
				},
				enabled_tools: []
			})
		);
	}

	createWorkspaceConversation(): Promise<Conversation> {
		return Promise.resolve(
			this.conversations.create({
				context: { kind: 'workspace', created_by: MOCK_WORKSPACE_ACCOUNT_ID },
				enabled_tools: []
			})
		);
	}

	/**
	 * Synchronous sibling of {@link createConversation}, for Stories/tests where
	 * awaiting a Promise at module-eval time is awkward. Not part of the public
	 * `AssistantDriver` interface.
	 */
	createConversationSync(input: CreateConversationInput): Conversation {
		return this.conversations.create(input);
	}

	getConversation(id: string): Promise<Conversation | null> {
		const conv = this.conversations.find(id);
		return Promise.resolve(conv ? this.withActive(conv) : null);
	}

	listConversations(params?: ListConversationsParams): Promise<ListConversationsResult> {
		const result = this.conversations.list(params);
		return Promise.resolve({
			data: result.data.map((c) => this.withActive(c)),
			meta: result.meta
		});
	}

	setConversationArchived(id: string, archived: boolean): Promise<Conversation> {
		const updated = this.conversations.setArchived(id, archived);
		if (!updated) {
			return Promise.reject(new Error(`Conversation ${id} not found`));
		}
		return Promise.resolve(updated);
	}

	renameConversation(id: string, title: string | null): Promise<Conversation> {
		const updated = this.conversations.rename(id, title);
		if (!updated) {
			return Promise.reject(new Error(`Conversation ${id} not found`));
		}
		return Promise.resolve(this.withActive(updated));
	}

	// ── Turn routes ──────────────────────────────────────────────────────────

	listTurns(conversationId: string): Promise<Turn[]> {
		return Promise.resolve(this.turns.list(conversationId));
	}

	latestTurn(conversationId: string): Promise<TurnSummary | null> {
		return Promise.resolve(this.turns.latest(conversationId));
	}

	recordTurn(conversationId: string, input: RecordTurnInput): Promise<Turn> {
		const conversation = this.conversations.find(conversationId);
		if (!conversation) {
			return Promise.reject(new Error(`Conversation ${conversationId} not found`));
		}
		return Promise.resolve(
			this.turns.create(conversationId, {
				request_messages: input.request_messages,
				response_messages: input.response_messages,
				usage: input.usage,
				finish_reason: input.finish_reason ?? null,
				error: input.error ?? null
			})
		);
	}

	// ── Stream route ─────────────────────────────────────────────────────────

	streamAsk(conversationId: string, input: StreamAskInput): AsyncIterable<AssistantSseEvent> {
		const session = new MockStreamSession(
			this.conversations,
			this.turns,
			this.scripts,
			this.cancelTokens,
			conversationId,
			input
		);
		this.activeSessions.set(session.token, session);
		const activeSessions = this.activeSessions;
		const cancelTokens = this.cancelTokens;

		// AsyncIterable wrapper that cleans up the active-session entry on exit.
		return {
			async *[Symbol.asyncIterator](): AsyncIterator<AssistantSseEvent> {
				try {
					yield* session.run();
				} finally {
					activeSessions.delete(session.token);
					cancelTokens.delete(session.token);
				}
			}
		};
	}

	cancel(turnToken: string): Promise<void> {
		this.cancelTokens.add(turnToken);
		this.activeSessions.get(turnToken)?.cancel();
		return Promise.resolve();
	}

	// ── Usage route ──────────────────────────────────────────────────────

	getUsage(): Promise<AssistantUsage> {
		return Promise.resolve(this.usage);
	}

	// ── Test helpers (not part of the public `AssistantDriver` interface) ───

	/** Direct seed: inserts a conversation row without going through `create`. */
	seedConversation(conv: Conversation): void {
		this.conversations.seed(conv);
	}

	/** Test helper: opens a `running` turn row — the server-side state a
	 * surface sees when it reloads while the backend is still generating.
	 * The token rides on the row, mirroring the persisted cancel token. */
	seedRunningTurn(conversationId: string, content: string, turnToken: string): Turn {
		return this.turns.create(conversationId, {
			request_messages: [{ role: 'user', content }],
			response_messages: [],
			usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 },
			status: 'running',
			turn_token: turnToken
		});
	}

	/** Test helper: completes the conversation's running turn as `done` with
	 * the given reply — the settle the catch-up poll waits for. No-op when
	 * the conversation has no running row. */
	settleRunningTurn(conversationId: string, reply: string): void {
		const running = this.turns.runningTurn(conversationId);
		if (!running) return;
		this.turns.complete(running.id, {
			response_messages: [{ role: 'assistant', content: reply }],
			usage: { prompt_tokens: 1, completion_tokens: 1, total_tokens: 2 },
			status: 'done',
			finish_reason: 'stop'
		});
	}

	/** Test helper: settles the conversation's running turn as `cancelled`,
	 * keeping the given partial reply — the row state the backend writes when
	 * the cancel POST lands but the `cancelled` frame never reaches the
	 * client. No-op when the conversation has no running row. */
	settleRunningTurnAsCancelled(conversationId: string, partialReply: string): void {
		const running = this.turns.runningTurn(conversationId);
		if (!running) return;
		this.turns.complete(running.id, {
			response_messages: [{ role: 'assistant', content: partialReply }],
			usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 },
			status: 'cancelled',
			finish_reason: null,
			error: 'cancelled'
		});
	}

	/** Derives the conversation `active` flag on the way out — the mock
	 * mirrors the backend, which computes it from the running-turn row
	 * rather than storing it. */
	private withActive(conv: Conversation): Conversation {
		return {
			...conv,
			active: this.turns.runningTurn(conv.id) !== null,
			// The backend api_hash lifts `context.title` into the flat field.
			title: (conv.context['title'] as string | undefined) ?? null
		};
	}

	/** Generates an isolated ULID — exposed for stories that need unique ids. */
	static ulid(): string {
		return ulid();
	}
}
