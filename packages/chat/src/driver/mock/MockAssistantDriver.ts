// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { AssistantDriver } from '../AssistantDriver.js';
import type {
	AssistantSseEvent,
	AssistantUsage,
	Conversation,
	CreateAppConversationInput,
	CreateConversationInput,
	CreateDomainBuilderConversationInput,
	CreateWorkspaceConversationInput,
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
 * App id the mock stamps on app conversations (`context.app_id`). The real
 * backend derives it from the authenticated caller; the mock has no session,
 * so hosts can scope the rail with this same constant.
 */
export const MOCK_APP_ID = 'core.app_demo';

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
 * const driver = createMockAssistant();
 * const conv = await driver.createWorkspaceConversation({ language: 'fr-CA' });
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

	createWorkspaceConversation(input: CreateWorkspaceConversationInput = {}): Promise<Conversation> {
		// The mock has no language concept — the scripted replies are English.
		return Promise.resolve(
			this.conversations.create({
				context: { kind: 'workspace', created_by: MOCK_WORKSPACE_ACCOUNT_ID },
				enabled_tools: []
			})
		);
	}

	createAppConversation(_input: CreateAppConversationInput = {}): Promise<Conversation> {
		// The mock has no language concept — the scripted replies are English.
		return Promise.resolve(
			this.conversations.create({
				context: { kind: 'app', app_id: MOCK_APP_ID },
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
		return Promise.resolve(this.conversations.find(id));
	}

	listConversations(params?: ListConversationsParams): Promise<ListConversationsResult> {
		return Promise.resolve(this.conversations.list(params));
	}

	setConversationArchived(id: string, archived: boolean): Promise<Conversation> {
		const updated = this.conversations.setArchived(id, archived);
		if (!updated) {
			return Promise.reject(new Error(`Conversation ${id} not found`));
		}
		return Promise.resolve(updated);
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

	/** Generates an isolated ULID — exposed for stories that need unique ids. */
	static ulid(): string {
		return ulid();
	}
}

/**
 * Creates an in-memory {@link MockAssistantDriver} — the no-network driver
 * for tests and offline development. Same arguments as the class
 * constructor: an ordered script list (defaults when omitted) and an
 * options bag (pinned usage meter).
 */
export function createMockAssistant(
	scripts: AssistantScript[] = defaultScripts,
	options: { usage?: AssistantUsage } = {}
): MockAssistantDriver {
	return new MockAssistantDriver(scripts, options);
}
