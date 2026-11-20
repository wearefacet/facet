// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

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
} from './types.js';

/**
 * Frontend entry point for the AI Assistant subsystem.
 *
 * The shape mirrors the backend `Assistant::Routes` HTTP surface
 * (`/Api/assistant/...`) and `Assistant::Stream::Session`'s SSE wire format:
 *
 * | Method | Route | Driver method |
 * |---|---|---|
 * | POST | `/Api/assistant/conversations` | {@link AssistantDriver.createConversation} |
 * | POST | `/Api/assistant/workspace/conversations` | {@link AssistantDriver.createWorkspaceConversation} |
 * | GET  | `/Api/assistant/conversations/:id` | {@link AssistantDriver.getConversation} |
 * | GET  | `/Api/assistant/conversations` | {@link AssistantDriver.listConversations} |
 * | PATCH | `/Api/assistant/conversations/:id` | {@link AssistantDriver.setConversationArchived} |
 * | GET  | `/Api/assistant/conversations/:id/turns` | {@link AssistantDriver.listTurns} |
 * | GET  | `/Api/assistant/conversations/:id/turns/latest` | {@link AssistantDriver.latestTurn} |
 * | POST | `/Api/assistant/conversations/:id/turns` | {@link AssistantDriver.recordTurn} |
 * | POST | `/Api/assistant/conversations/:id/stream` | {@link AssistantDriver.streamAsk} |
 * | POST | `/Api/assistant/cancel/:turn_token` | {@link AssistantDriver.cancel} |
 * | GET  | `/Api/assistant/usage` | {@link AssistantDriver.getUsage} |
 *
 * Two concrete implementations exist:
 * - `HttpAssistantDriver` (`./http-assistant-driver.js`) — talks to the real backend over fetch + SSE.
 * - `MockAssistantDriver` (`./mock/MockAssistantDriver.js`) — in-memory, scripted
 *   responses for Storybook and component tests.
 *
 * `streamAsk` returns an async iterable of {@link AssistantSseEvent} rather than
 * a raw `ReadableStream`; this lets Svelte components consume events with
 * `for await…of` and update runes incrementally without an EventSource shim.
 */
export interface AssistantDriver {
	/** Create a conversation row. Mirrors `POST /Api/assistant/conversations`. */
	createConversation(input: CreateConversationInput): Promise<Conversation>;

	/**
	 * Create a domain-builder conversation bound to a draft domain.
	 * Mirrors `POST /Api/assistant/domain-builder/conversations`.
	 *
	 * When `draft_domain` is provided, the conversation is created against an
	 * existing draft domain. When omitted, a new empty draft domain is created.
	 */
	createDomainBuilderConversation(
		input: CreateDomainBuilderConversationInput
	): Promise<Conversation>;

	/**
	 * Create a workspace (main-application) conversation owned by the
	 * signed-in account. Mirrors `POST /Api/assistant/workspace/conversations`.
	 * The backend owns the model, system prompt, tool set, and the context
	 * (kind + owner — always the caller); the body carries only the user's
	 * current language, which the driver injects from the paraglide locale.
	 *
	 * @throws 403 (`HttpAssistantError`) when no held role carries
	 *   `assistant_access` (`Assistant::Access`).
	 */
	createWorkspaceConversation(): Promise<Conversation>;

	/** Fetch a conversation by id, or `null` if not found. Mirrors `GET /:id`. */
	getConversation(id: string): Promise<Conversation | null>;

	/**
	 * List conversations, `updated_at DESC` by default. Mirrors
	 * `GET /Api/assistant/conversations`. Pass {@link ListConversationsParams}
	 * to filter (e.g. by `context.kind__eq`) or to paginate for infinite scroll.
	 * The response carries `{ data, meta }` so callers know whether more pages
	 * are available via `meta.more`. The list is live-only unless a filter
	 * `archived__eq=true` asks for the archived rows.
	 */
	listConversations(params?: ListConversationsParams): Promise<ListConversationsResult>;

	/**
	 * Archive or unarchive a conversation. Mirrors
	 * `PATCH /Api/assistant/conversations/:id` with `{ archived: boolean }`.
	 * Archiving is a list-organisation state: archived rows leave the default
	 * list, the conversation stays readable and streamable, and its next turn
	 * unarchives it server-side.
	 */
	setConversationArchived(id: string, archived: boolean): Promise<Conversation>;

	/** List turns of a conversation in `idx` order. Mirrors `GET /:id/turns`. */
	listTurns(conversationId: string): Promise<Turn[]>;

	/**
	 * Latest turn summary of a conversation, or `null` when it has no turns.
	 * Mirrors `GET /:id/turns/latest`. Carries no message payloads — the
	 * catch-up poll reads it to learn whether an in-flight turn reached its
	 * terminal state.
	 */
	latestTurn(conversationId: string): Promise<TurnSummary | null>;

	/**
	 * Manually record a turn row. Mirrors `POST /:id/turns`.
	 *
	 * In normal use turns are persisted server-side by `Stream::Session` and
	 * surfaced via `listTurns`; this method exists for parity with the backend
	 * and for tests that pre-seed history.
	 */
	recordTurn(conversationId: string, input: RecordTurnInput): Promise<Turn>;

	/**
	 * Stream one turn against the assistant.
	 *
	 * Mirrors `POST /Api/assistant/conversations/:id/stream`. Returns an async
	 * iterable that yields {@link AssistantSseEvent}s in order — `meta`, zero or
	 * more `chunk`s, then exactly one terminal event (`done` / `error` /
	 * `cancelled`). A {@link Turn} row is persisted internally on every exit
	 * path, matching `Stream::Session#run`.
	 *
	 * The caller may pass the returned `turn_token` (captured from the first
	 * `meta` event) to {@link AssistantDriver.cancel} to abort the in-flight
	 * turn; the iterator then emits `cancelled` and ends.
	 *
	 * @throws if the conversation does not exist.
	 */
	streamAsk(conversationId: string, input: StreamAskInput): AsyncIterable<AssistantSseEvent>;

	/**
	 * Cancel an in-flight streaming turn. Mirrors
	 * `POST /Api/assistant/cancel/:turn_token`. Resolves once the cancel signal
	 * is published; the corresponding `streamAsk` iterator emits `cancelled`
	 * asynchronously.
	 */
	cancel(turnToken: string): Promise<void>;

	/** The caller's rolling-window usage meter data. Mirrors `GET /Api/assistant/usage`. */
	getUsage(): Promise<AssistantUsage>;
}
