// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { AssistantDriver } from './AssistantDriver.js';
import type {
	AgentMessage,
	AssistantSseEvent,
	AssistantUsage,
	Conversation,
	CreateConversationInput,
	CreateDomainBuilderConversationInput,
	ListConversationsParams,
	ListConversationsResult,
	RecordTurnInput,
	StreamAskInput,
	StreamChunk,
	Turn,
	TurnSummary
} from './types.js';
import { HttpAssistantError, readErrorMessage } from './errors.js';
import { apiFetch } from '../session.svelte';
import { serializeFilterValue } from '$lib/datasource/filterParams.js';
import { getLocale } from '$lib/paraglide/runtime';
import * as m from '$lib/paraglide/messages';

// Re-exported so consumers of this module (and of `$lib/assistant/index.js`)
// keep importing the error type from the driver barrel.
export { HttpAssistantError, readErrorMessage };

/**
 * The CSRF header the backend demands on every state-changing
 * `/Api/assistant` route — same rule as the IAM / notifications writers.
 */
const XMLHttpRequest_HEADER = 'XMLHttpRequest';

/**
 * Real `AssistantDriver` that talks to the Facet backend over `fetch` +
 * SSE. Mirrors `Facet::Assistant::Routes` and the SSE wire format emitted
 * by `Facet::Assistant::Stream::Session`.
 *
 * `streamAsk` consumes the `fetch` response body as a `ReadableStream<Uint8Array>`
 * and parses SSE frames into typed {@link AssistantSseEvent}s. Unlike
 * `EventSource`, this works with `POST` requests and custom bodies.
 *
 * All non-2xx responses throw an {@link HttpAssistantError} whose `message`
 * is the backend's `{error: "…"}` payload (or the status text as a fallback).
 *
 * Every POST sends `X-Requested-With` — the assistant routes are
 * CSRF-checked server-side.
 */
export class HttpAssistantDriver implements AssistantDriver {
	private readonly baseUrl: string;

	/**
	 * @param baseUrl Origin + optional path prefix for the API. Defaults to
	 *   `''` (same-origin), which is correct when a Vite dev proxy or production
	 *   reverse-proxy forwards `/Api/...` to the Crystal backend.
	 */
	constructor(baseUrl = '') {
		this.baseUrl = baseUrl;
	}

	// ── Conversation routes ─────────────────────────────────────────────────

	async createConversation(input: CreateConversationInput): Promise<Conversation> {
		const res = await this.post('/Api/assistant/conversations', withLanguage(input));
		return (await res.json()).data as Conversation;
	}

	async createDomainBuilderConversation(
		input: CreateDomainBuilderConversationInput
	): Promise<Conversation> {
		const res = await this.post('/Api/assistant/domain-builder/conversations', withLanguage(input));
		return (await res.json()).data as Conversation;
	}

	async createWorkspaceConversation(): Promise<Conversation> {
		const res = await this.post('/Api/assistant/workspace/conversations', {
			language: getLocale()
		});
		return (await res.json()).data as Conversation;
	}

	async getConversation(id: string): Promise<Conversation | null> {
		const res = await this.fetch(
			`${this.baseUrl}/Api/assistant/conversations/${encodeURIComponent(id)}`,
			{
				method: 'GET'
			}
		);
		if (res.status === 404) return null;
		await this.assertOk(res);
		return (await res.json()).data as Conversation;
	}

	async listConversations(params?: ListConversationsParams): Promise<ListConversationsResult> {
		const qs = buildListQuery(params);
		const res = await this.fetch(`${this.baseUrl}/Api/assistant/conversations${qs}`, {
			method: 'GET'
		});
		await this.assertOk(res);
		const body = (await res.json()) as {
			data: Conversation[];
			meta: { count: number; more: boolean };
		};
		return { data: body.data, meta: body.meta };
	}

	async setConversationArchived(id: string, archived: boolean): Promise<Conversation> {
		const res = await this.fetch(
			`${this.baseUrl}/Api/assistant/conversations/${encodeURIComponent(id)}`,
			{
				method: 'PATCH',
				headers: {
					'Content-Type': 'application/json',
					'X-Requested-With': XMLHttpRequest_HEADER
				},
				body: JSON.stringify({ archived })
			}
		);
		await this.assertOk(res);
		return (await res.json()).data as Conversation;
	}

	// ── Turn routes ──────────────────────────────────────────────

	async listTurns(conversationId: string): Promise<Turn[]> {
		const res = await this.fetch(
			`${this.baseUrl}/Api/assistant/conversations/${encodeURIComponent(conversationId)}/turns`,
			{ method: 'GET' }
		);
		await this.assertOk(res);
		return (await res.json()).data as Turn[];
	}

	async latestTurn(conversationId: string): Promise<TurnSummary | null> {
		const res = await this.fetch(
			`${this.baseUrl}/Api/assistant/conversations/${encodeURIComponent(conversationId)}/turns/latest`,
			{ method: 'GET' }
		);
		await this.assertOk(res);
		const body = (await res.json()) as {
			data:
				| (TurnSummary & {
						request_messages?: AgentMessage[] | null;
						response_messages?: AgentMessage[] | null;
				  })
				| null;
		};
		if (!body.data) return null;
		// An older payload may omit the message arrays — empty is the safe read.
		return {
			...body.data,
			request_messages: body.data.request_messages ?? [],
			response_messages: body.data.response_messages ?? []
		};
	}

	async recordTurn(conversationId: string, input: RecordTurnInput): Promise<Turn> {
		const res = await this.post(
			`/Api/assistant/conversations/${encodeURIComponent(conversationId)}/turns`,
			input
		);
		return (await res.json()).data as Turn;
	}

	// ── Stream + cancel ───────────────────────────────────────────────────

	async *streamAsk(
		conversationId: string,
		input: StreamAskInput
	): AsyncIterable<AssistantSseEvent> {
		const res = await this.fetch(
			`${this.baseUrl}/Api/assistant/conversations/${encodeURIComponent(conversationId)}/stream`,
			{
				method: 'POST',
				headers: {
					'Content-Type': 'application/json',
					Accept: 'text/event-stream',
					'X-Requested-With': XMLHttpRequest_HEADER
				},
				body: JSON.stringify(input)
			}
		);
		await this.assertOk(res);
		if (!res.body) throw new Error(m.errors_streaming_unsupported());

		yield* parseSseStream(res.body);
	}

	async cancel(turnToken: string): Promise<void> {
		const res = await this.fetch(
			`${this.baseUrl}/Api/assistant/cancel/${encodeURIComponent(turnToken)}`,
			{
				method: 'POST',
				headers: { 'Content-Type': 'application/json', 'X-Requested-With': XMLHttpRequest_HEADER },
				body: '{}'
			}
		);
		await this.assertOk(res);
	}

	// ── Usage ─────────────────────────────────────────────────────────────

	/**
	 * The caller's rolling-window usage meter. Mirrors
	 * `GET /Api/assistant/usage`. `budget: null` means unlimited — the UI
	 * hides the meter for it.
	 */
	async getUsage(): Promise<AssistantUsage> {
		const res = await this.fetch(`${this.baseUrl}/Api/assistant/usage`, { method: 'GET' });
		await this.assertOk(res);
		return (await res.json()) as AssistantUsage;
	}

	// ── Fetch helpers ─────────────────────────────────────────────────────

	private async post(path: string, body: unknown): Promise<Response> {
		const res = await this.fetch(`${this.baseUrl}${path}`, {
			method: 'POST',
			headers: { 'Content-Type': 'application/json', 'X-Requested-With': XMLHttpRequest_HEADER },
			body: JSON.stringify(body)
		});
		await this.assertOk(res);
		return res;
	}

	/**
	 * Thin wrapper around `apiFetch` so the class is testable / mockable
	 * via dependency injection if needed. Kept separate from `post` so the SSE
	 * path can pass stream-friendly headers without a JSON content-type.
	 * Uses `apiFetch` for automatic token refresh on authenticated calls.
	 */
	protected fetch(input: string, init?: RequestInit): Promise<Response> {
		return apiFetch(input, init);
	}

	private async assertOk(res: Response): Promise<void> {
		if (res.ok) return;
		// Clone so the body is still readable by the caller on success paths.
		const message = await readErrorMessage(res.clone());
		throw new HttpAssistantError(res.status, res.statusText, message);
	}
}

/**
 * Adds the user's current language to a conversation-create body. The
 * backend bakes it into the system prompt (`## Language` directive — see
 * `Facet::Assistant::Language`). An explicit `language` on the input wins,
 * so tests and API callers can pin one.
 */
function withLanguage<T extends { language?: string }>(input: T): T & { language: string } {
	return { ...input, language: input.language ?? getLocale() };
}

/**
 * Builds the query string for `GET /Api/assistant/conversations` from
 * {@link ListConversationsParams}. Mirrors the query-string format accepted
 * by `Facet::HTTP::ListRequest.from_request` — `filters[field__op]=value`
 * and `sort=-field,other`.
 */
export function buildListQuery(params?: ListConversationsParams): string {
	if (!params) return '';
	const parts = new URLSearchParams();
	if (params.page != null) parts.set('page', String(params.page));
	if (params.items != null) parts.set('items', String(params.items));
	if (params.sort && params.sort.length) parts.set('sort', params.sort.join(','));
	if (params.filters) {
		for (const [key, value] of Object.entries(params.filters)) {
			parts.set(`filters[${key}]`, serializeFilterValue(value));
		}
	}
	const qs = parts.toString();
	return qs ? `?${qs}` : '';
}

/**
 * Parses a `ReadableStream<Uint8Array>` of SSE text into an async iterable of
 * {@link AssistantSseEvent}. Handles partial frames across chunk boundaries
 * and multi-line `data:` payloads (concatenated with `\n`).
 *
 * The SSE wire format from the backend is:
 *
 * ```
 * event: meta\n
 * data: {"turn_token":"…"}\n
 * \n
 * event: chunk\n
 * data: {"kind":"content","text":"…"}\n
 * \n
 * ```
 *
 * Each blank-line-delimited frame yields exactly one event. `event:` sets the
 * event type; `data:` lines are concatenated. The parser maps the
 * `event`+`data` pair onto a typed variant and yields it.
 */
export async function* parseSseStream(
	stream: ReadableStream<Uint8Array>
): AsyncIterable<AssistantSseEvent> {
	const reader = stream.getReader();
	const decoder = new TextDecoder();
	let buffer = '';

	try {
		// Tracks the event type and data lines of the frame currently being
		// accumulated across chunk boundaries.
		let event: string | null = null;
		let dataLines: string[] = [];

		while (true) {
			const { value, done } = await reader.read();
			if (done) break;

			buffer += decoder.decode(value, { stream: true });

			// Process complete lines (terminated by `\n`). The SSE spec says
			// lines may end with `\n` or `\r\n`; we normalise both.
			let newlineIdx: number;
			while ((newlineIdx = buffer.indexOf('\n')) !== -1) {
				const rawLine = buffer.slice(0, newlineIdx);
				// Strip a trailing `\r` if present (CRLF line endings).
				const line = rawLine.endsWith('\r') ? rawLine.slice(0, -1) : rawLine;
				buffer = buffer.slice(newlineIdx + 1);

				// A blank line terminates a frame → dispatch it.
				if (line === '') {
					if (event !== null && dataLines.length > 0) {
						const dataStr = dataLines.join('\n');
						yield parseSseEvent(event!, dataStr);
					}
					event = null;
					dataLines = [];
					continue;
				}

				// Lines without a colon prefix are ignored by the SSE spec.
				const colonIdx = line.indexOf(':');
				if (colonIdx === -1) continue;
				const field = line.slice(0, colonIdx);
				// A leading space after the colon is stripped per spec.
				let val = line.slice(colonIdx + 1);
				if (val.startsWith(' ')) val = val.slice(1);

				if (field === 'event') {
					event = val;
				} else if (field === 'data') {
					dataLines.push(val);
				}
				// `id:` and `retry:` fields are not used by the assistant stream.
			}
		}
	} finally {
		reader.releaseLock();
	}
}

/**
 * Maps a single parsed SSE frame (`event` + `data` JSON string) onto the
 * discriminated-union {@link AssistantSseEvent} type.
 */
function parseSseEvent(event: string, dataStr: string): AssistantSseEvent {
	// The `cancelled` event carries an empty `{}` payload.
	if (event === 'cancelled') return { event: 'cancelled' };

	let data: Record<string, unknown>;
	try {
		data = JSON.parse(dataStr);
	} catch {
		// Malformed JSON — treat as an error event so the UI surfaces it.
		return { event: 'error', message: `Malformed SSE data: ${dataStr}` };
	}

	switch (event) {
		case 'meta':
			return { event: 'meta', turn_token: data.turn_token as string };
		case 'chunk':
			return { event: 'chunk', chunk: data as StreamChunk };
		case 'done':
			return {
				event: 'done',
				turn_id: data.turn_id as string,
				finish_reason: data.finish_reason as string
			};
		case 'error':
			return { event: 'error', message: data.message as string };
		default:
			// Unknown event type — treat as an error so the UI surfaces it.
			return { event: 'error', message: `Unknown SSE event: ${event}` };
	}
}
