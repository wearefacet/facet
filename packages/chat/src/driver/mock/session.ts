// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type {
	AssistantSseEvent,
	Conversation,
	StreamAskInput,
	ToolCallRef,
	Turn,
	Usage
} from '../types.js';
import type { AssistantScript } from './scripts.js';
import type { MockConversationStore } from './conversation.js';
import type { MockTurnStore } from './turn.js';
import { ulid } from './conversation.js';

/**
 * In-memory analog of `Assistant::Stream::Session`.
 *
 * Orchestrates one streaming turn against a scripted {@link AssistantScript}:
 * emits `meta` → `chunk`* → terminal event (`done`/`error`/`cancelled`),
 * persists a `Turn` row on every exit path, and tears down the cancel
 * subscription — same shape as the backend, minus the Redis cancel bus (an
 * in-memory `Set<turnToken>` flag does the same job synchronously).
 *
 * The class is constructed per-call but holds a back-reference to the shared
 * stores and the cancel-token set owned by {@link MockAssistantDriver}.
 */
export class MockStreamSession {
	private cancelled = false;
	private readonly turnToken = ulid();

	constructor(
		private readonly conversations: MockConversationStore,
		private readonly turns: MockTurnStore,
		private readonly scripts: AssistantScript[],
		private readonly cancelTokens: Set<string>,
		private readonly conversationId: string,
		private readonly input: StreamAskInput
	) {}

	/**
	 * Runs a streaming turn, yielding SSE events to the caller. Persists a
	 * `Turn` row on every exit path. Returns the synchronous outcome on
	 * completion — `agent-cr` analog is `Result` in `session.cr`.
	 *
	 * Mirrors the backend lifecycle: the row is opened (`running`) before
	 * the first event and completed at the exit path, so a rerender during
	 * the stream sees a `running` row through `latestTurn`.
	 */
	async *run(): AsyncGenerator<AssistantSseEvent> {
		const conversation = this.conversations.find(this.conversationId);
		if (!conversation) {
			yield { event: 'error', message: `Conversation ${this.conversationId} not found` };
			return;
		}

		// Open the running row — mirrors `Turn.open` in the stream route.
		const turn = this.turns.create(conversation.id, {
			request_messages: [{ role: 'user', content: this.input.content }],
			response_messages: [],
			usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 },
			status: 'running'
		});

		const script = this.pickScript(conversation);

		// meta — emitted first so the caller knows the cancel token before chunks.
		yield { event: 'meta', turn_token: this.turnToken };

		if (!script) {
			yield { event: 'error', message: 'No script matched the message' };
			this.complete(turn.id, 'error', 'No script matched');
			return;
		}

		// Stream chunks, observing cancellation between each step.
		for (const [i, step] of script.chunks.entries()) {
			if (this.shouldCancel()) {
				yield { event: 'cancelled' };
				this.completeCancelled(turn.id, script);
				return;
			}
			if (step.delayMs && step.delayMs > 0) {
				await sleep(step.delayMs);
				if (this.shouldCancel()) {
					yield { event: 'cancelled' };
					this.completeCancelled(turn.id, script);
					return;
				}
			}
			yield { event: 'chunk', chunk: step };
			// Checkpoint the partial exchange into the running row — the same
			// write the backend does between iterations, so a catch-up poll
			// sees the trace grow.
			this.turns.checkpoint(turn.id, scriptToMessages(script.chunks.slice(0, i + 1)));
		}

		// Terminal event.
		switch (script.outcome.kind) {
			case 'done': {
				const usage: Usage = script.usage ?? {
					prompt_tokens: 0,
					completion_tokens: 0,
					total_tokens: 0
				};
				yield {
					event: 'done',
					turn_id: turn.id,
					finish_reason: script.outcome.finish_reason
				};
				this.turns.complete(turn.id, {
					response_messages: scriptToMessages(script.chunks),
					usage,
					status: 'done',
					finish_reason: script.outcome.finish_reason
				});
				break;
			}
			case 'error':
				yield { event: 'error', message: script.outcome.message };
				this.complete(turn.id, 'error', script.outcome.message);
				break;
			case 'capped': {
				// The tool-call loop hit the agent's iteration cap — the mock
				// emits the normal `error` SSE event, then completes the row with
				// status `capped`, keeping the streamed exchange as the persisted
				// partial (the next turn replays it).
				const message =
					script.outcome.message ?? 'Agent error: tool call iteration limit (100) exceeded';
				yield { event: 'error', message };
				this.turns.complete(turn.id, {
					response_messages: scriptToMessages(script.chunks),
					usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 },
					status: 'capped',
					finish_reason: null,
					error: message
				});
				break;
			}
			case 'cancelled':
				// Script-level cancel (rare; used when the script itself says "end cancelled").
				yield { event: 'cancelled' };
				this.completeCancelled(turn.id, script);
				break;
		}
	}

	/** Called by {@link MockAssistantDriver.cancel} to flag this turn. */
	cancel(): void {
		this.cancelled = true;
	}

	/** Token the caller can pass to `MockAssistantDriver.cancel`. */
	get token(): string {
		return this.turnToken;
	}

	private pickScript(conversation: Conversation): AssistantScript | null {
		for (const s of this.scripts) {
			if (s.match(this.input.content, conversation.context)) return s;
		}
		return null;
	}

	/**
	 * Cancelled iff the local flag was set OR the driver received a
	 * `cancel(turn_token)` call (cross-fiber, in case another caller path
	 * races us). Matches the backend's "subscriber fiber + response_box" idea
	 * but with a single Set lookup.
	 */
	private shouldCancel(): boolean {
		return this.cancelled || this.cancelTokens.has(this.turnToken);
	}

	/**
	 * Cancels keep the partial context the script produced so far — same
	 * contract as the backend: `response_messages` holds the streamed
	 * assistant reply, `status` is `cancelled`, `error` is `"cancelled"`.
	 */
	private completeCancelled(turnId: string, script: AssistantScript): void {
		this.turns.complete(turnId, {
			response_messages: scriptToMessages(script.chunks),
			usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 },
			status: 'cancelled',
			finish_reason: null,
			error: 'cancelled'
		});
	}

	private complete(turnId: string, status: 'error', message: string): void {
		this.turns.complete(turnId, {
			response_messages: [],
			usage: { prompt_tokens: 0, completion_tokens: 0, total_tokens: 0 },
			status,
			finish_reason: null,
			error: message
		});
	}
}

/**
 * Reconstructs a sequence of `Agent::Message`-shaped objects from scripted
 * chunks, mirroring what `Assistant::Stream::Session` persists from a real
 * `agent-cr` turn.
 *
 * `content`/`reasoning` chunks accumulate into the current assistant
 * message's text. A `tool_call` chunk with status `running` adds a tool call
 * to that *same* assistant message — agents stream their preamble text, then
 * declare the call, so text and tool_calls share one message (this is what
 * agent-cr's `build_final_message` produces). An `ok`/`error` chunk flushes
 * the assistant message and emits a following tool-result message keyed by
 * the tool call's id; any later content opens a fresh assistant message
 * (the model's post-tool continuation round-trip).
 *
 * `reasoning` chunks accumulate into the assistant message's `reasoning`
 * field (not its `content`), matching `Agent::Message`'s persisted shape.
 *
 * The persisted shape mirrors the real backend, so `reconstructTurns` replays
 * it back into the same UI view-model on reload.
 */
function scriptToMessages(chunks: AssistantScript['chunks']): Turn['response_messages'] {
	const messages: Turn['response_messages'] = [];
	let currentAssistant: {
		role: 'assistant';
		content: string;
		reasoning?: string;
		tool_calls: ToolCallRef[];
	} | null = null;
	let pendingToolId: string | null = null;
	let toolIdx = 0;

	function ensureAssistant(): void {
		if (!currentAssistant) {
			currentAssistant = { role: 'assistant', content: '', reasoning: '', tool_calls: [] };
		}
	}

	function flushAssistant(): void {
		if (currentAssistant && (currentAssistant.content || currentAssistant.tool_calls.length)) {
			const msg: Turn['response_messages'][number] = {
				role: 'assistant',
				content: currentAssistant.content,
				tool_calls: currentAssistant.tool_calls
			};
			if (currentAssistant.reasoning) msg.reasoning = currentAssistant.reasoning;
			messages.push(msg);
		}
		currentAssistant = null;
	}

	for (const c of chunks) {
		if (c.kind === 'content') {
			ensureAssistant();
			currentAssistant!.content += c.text;
		} else if (c.kind === 'reasoning') {
			ensureAssistant();
			currentAssistant!.reasoning = (currentAssistant!.reasoning ?? '') + c.text;
		} else if (c.kind === 'tool_call') {
			if (c.status === 'running') {
				// The tool call joins the current assistant message (with any
				// preceding preamble text), matching the real backend.
				ensureAssistant();
				const id = `call_mock_${toolIdx++}`;
				currentAssistant!.tool_calls.push({
					id,
					name: c.name,
					arguments: c.arguments ?? '{}'
				});
				pendingToolId = id;
			} else {
				// `ok` / `error` — close the assistant message, then emit the
				// tool result keyed by the pending tool call id.
				flushAssistant();
				const id = pendingToolId ?? `call_mock_${toolIdx - 1}`;
				messages.push({
					role: 'tool',
					tool_call_id: id,
					name: c.name,
					content: c.result ?? (c.status === 'error' ? 'Error executing tool' : '')
				});
				pendingToolId = null;
			}
		}
	}
	flushAssistant();
	return messages;
}

function sleep(ms: number): Promise<void> {
	return new Promise((resolve) => setTimeout(resolve, ms));
}
