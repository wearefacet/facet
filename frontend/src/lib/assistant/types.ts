// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Core assistant types — mirror the shapes exchanged over the
 * `/Api/assistant/...` HTTP routes and the SSE stream.
 *
 * Mirrors backend `src/assistant/conversation.cr`, `src/assistant/turn.cr`,
 * and the SSE wire format emitted by `src/assistant/stream/session.cr`
 * (including `tool_call` chunks emitted by `ToolTraceHandler`).
 */

// ── Conversation ───────────────────────────────────────────────────────────

/** A row from `agent_conversations` — mirrors `Assistant::Conversation::Record`. */
export interface Conversation {
	id: string;
	session_id: string;
	cache_key: string;
	system_prompt: string | null;
	context: Record<string, unknown>;
	enabled_tools: string[];
	created_at: string;
	updated_at: string;
	/** Archive stamp — `null` for a live conversation. Archiving hides the
	 * row from the default list only; a new turn unarchives. */
	archived_at: string | null;
	/** Derived status: true while the conversation has a `running` turn —
	 * the flag the rail renders as its running icon. Server-computed on the
	 * list / get surfaces. */
	active: boolean;
}

/** Body of `POST /Api/assistant/conversations`. */
export interface CreateConversationInput {
	/** Free-form context describing what the conversation is for. */
	context?: Record<string, unknown>;
	/** Names of tools the agent may call (defaults to empty on backend). */
	enabled_tools?: string[];
	/**
	 * BCP-47 tag of the user's current language. The backend bakes it into
	 * the system prompt as a `## Language` directive. The driver injects the
	 * paraglide locale when the caller omits it.
	 */
	language?: string;
}

/** Body of `POST /Api/assistant/domain-builder/conversations`. */
export interface CreateDomainBuilderConversationInput {
	/** Existing draft domain id to bind the conversation to. When omitted, a new empty draft is created. */
	draft_domain?: string;
	/** Advisory target live name, interpolated into the system prompt. */
	target_name?: string;
	/** Advisory intent description, interpolated into the system prompt. */
	description?: string;
	/**
	 * BCP-47 tag of the user's current language. The backend bakes it into
	 * the system prompt as a `## Language` directive. The driver injects the
	 * paraglide locale when the caller omits it.
	 */
	language?: string;
}

/**
 * Parameters for `AssistantDriver.listConversations`.
 *
 * Mirrors `ListRequest` (`src/http/list_request.cr`):
 * - `page` (default 1), `items` (default 100, clamped 1..1000)
 * - `filters`: `field__op=value` pairs. Three filter families are supported by
 *   the backend on `agent_conversations`:
 *   - `context.<key>__eq=value` — jsonb containment on `context` (multiple
 *     keys are AND-ed into one `context @> $N::jsonb` predicate).
 *   - `<column>__op=value` on `id`, `session_id`, `cache_key`,
 *     `created_at`, `updated_at` (text eq/ne/match; timestamp eq/ne/gt/gte/lt/lte).
 *   - `archived__eq=true` — archived rows only. Without it (or with any
 *     other value) the list shows live rows only.
 * - `sort`: array of column names, optionally prefixed with `-` for
 *   descending. Sortable columns: `id`, `created_at`, `updated_at`.
 *   Default: `['-updated_at']`.
 */
export interface ListConversationsParams {
	page?: number;
	items?: number;
	filters?: Record<string, string | number | boolean>;
	sort?: string[];
}

/** Collection response shape returned by `GET /Api/assistant/conversations`. */
export interface ListConversationsResult {
	data: Conversation[];
	meta: { count: number; more: boolean };
}

// ── Turn ────────────────────────────────────────────────────────────────────

/**
 * A tool call attached to an assistant message — mirrors the
 * `Agent::ToolCall` struct as serialised by `JSON::Serializable` (the
 * shape stored in `agent_turns.response_messages` jsonb). This is the flat
 * `{id, name, arguments}` form, NOT the OpenAI wire format
 * (`{id, type, function:{name, arguments}}`) — that wrapping is only
 * applied by `Agent::Message#to_request_body` when sending to the provider.
 */
export interface ToolCallRef {
	id: string;
	name: string;
	arguments: string;
}

/** A `Agent::Message`-shaped record stored inside `Turn.request_messages` / `response_messages`. */
export interface AgentMessage {
	role: 'user' | 'assistant' | 'tool' | 'system';
	content: string;
	/** Assistant messages may carry tool calls. */
	tool_calls?: ToolCallRef[];
	tool_call_id?: string;
	name?: string;
	/** Assistant messages may carry model reasoning content (the "thought" block). */
	reasoning?: string;
}

/** `Agent::Usage` snapshot — mirrors the persisted jsonb shape. */
export interface Usage {
	prompt_tokens: number;
	completion_tokens: number;
	total_tokens: number;
}

/** A row from `agent_turns` — mirrors `Assistant::Turn::Record`. */
export interface Turn {
	id: string;
	conversation_id: string;
	idx: number;
	request_messages: AgentMessage[];
	response_messages: AgentMessage[];
	/**
	 * Turn lifecycle — mirrors the backend `status` column. `running` rows
	 * exist between `Turn.open` (stream start) and the turn's exit path; a
	 * stale one was swept to `error` with message `interrupted`. `capped` =
	 * the tool-call loop hit the agent's iteration cap; the row keeps the
	 * partial exchange and replays it on the next turn.
	 */
	status: 'running' | 'done' | 'error' | 'cancelled' | 'capped';
	usage: Usage;
	finish_reason: string | null;
	error: string | null;
	/** Streaming cancel token — non-null on a row opened by the stream
	 * route. Lets a surface that missed the SSE `meta` event (page reload
	 * mid-turn) re-arm the stop button against the running turn. */
	turn_token: string | null;
	created_at: string;
}

/**
 * Latest-turn summary — mirrors `GET /:id/turns/latest`. Carries the latest
 * row's messages so a catch-up watch can render the running turn's progress
 * while it generates; still cheap — one row. `null` responses map to a
 * conversation with no turns yet.
 */
export interface TurnSummary {
	id: string;
	idx: number;
	status: 'running' | 'done' | 'error' | 'cancelled' | 'capped';
	finish_reason: string | null;
	error: string | null;
	/** Cancel token of the row — the running row's token lets a reloaded
	 * surface cancel the in-flight turn. */
	turn_token: string | null;
	/** The latest row's messages. A `running` row's `response_messages` hold
	 * the checkpointed partial exchange; empty when the row has none. */
	request_messages: AgentMessage[];
	response_messages: AgentMessage[];
	created_at: string;
}

// ── Usage meter ────────────────────────────────────────────────────────────

/**
 * Response of `GET /Api/assistant/usage` — the caller's rolling-window token
 * meter, mirrored on `AssistantDriver.getUsage`. `budget: null` means
 * unlimited; the UI hides the meter for it.
 */
export interface AssistantUsage {
	/** Total tokens billed to the caller inside the current window. */
	total: number;
	/** The part of {@link total} the provider never reported on — a
	 * character-count estimate, not a bill. `total - estimated_total` is the
	 * reported part. Absent on older payloads — treat as `0`. */
	estimated_total?: number;
	/** Effective token budget, or `null` when the account is unlimited. */
	budget: number | null;
	/** RFC-3339 UTC start of the current rolling window. */
	window_start: string;
	/** Window length in days. */
	window_days: number;
}

// ── SSE stream events ─────────────────────────────────────────────────────────

/**
 * The set of `Response#stream` chunk kinds that appear on the SSE wire.
 * `content` and `reasoning` come straight from `agent-cr`; `tool_call` is
 * emitted by `Facet::Assistant::Stream::ToolTraceHandler` (registered on
 * every turn's `Agent`), which fires on the `ToolCallContext` stage of
 * agent-cr's handler chain — once before the callback runs (`running`) and
 * once after (`ok`/`error`).
 */
export type StreamChunkKind = 'content' | 'reasoning' | 'tool_call';

/** Status of a single tool call chunk. Matches `ToolCallBar`'s `status` prop. */
export type ToolCallStatus = 'running' | 'ok' | 'error';

/**
 * A chunk emitted on the stream. The `tool_call` variant is emitted by
 * `ToolTraceHandler`; `content` and `reasoning` come straight from
 * `agent-cr`'s stream parser.
 */
export type StreamChunk =
	| { kind: 'content'; text: string }
	| { kind: 'reasoning'; text: string }
	| {
			kind: 'tool_call';
			name: string;
			detail?: string;
			result?: string;
			status: ToolCallStatus;
			/** Raw JSON arguments — sent only for UI tools (`ui-tools.ts`),
			 * whose effect is rendered by the chat UI itself. */
			arguments?: string;
	  };

/** Body of `POST /Api/assistant/conversations/:id/stream`. */
export interface StreamAskInput {
	content: string;
	attachments?: string[];
}

/**
 * Discriminated union of every SSE event the
 * `POST /Api/assistant/conversations/:id/stream` endpoint can emit.
 *
 *   event: meta   → { turn_token }
 *   event: chunk  → { kind, text | {name,detail,result,status} }
 *   event: done   → { turn_id, finish_reason }
 *   event: error   → { message }
 *   event: cancelled → {}
 */
export type AssistantSseEvent =
	| { event: 'meta'; turn_token: string }
	| { event: 'chunk'; chunk: StreamChunk }
	| { event: 'done'; turn_id: string; finish_reason: string }
	| { event: 'error'; message: string }
	| { event: 'cancelled' };

/** Outcome of a streamed turn — passed to the caller when the iterator ends. */
export interface StreamTurnResult {
	turn_id: string | null;
	finish_reason: string | null;
	error: string | null;
	cancelled: boolean;
}

/** Body of `POST /Api/assistant/conversations/:id/turns` — manual turn record. */
export interface RecordTurnInput {
	request_messages: AgentMessage[];
	response_messages: AgentMessage[];
	usage: Usage;
	finish_reason?: string;
	error?: string;
}
