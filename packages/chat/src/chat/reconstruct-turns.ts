// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { AgentMessage, ToolCallRef } from '../driver/types.js';
import type {
	AgentPart,
	ListRows,
	Stats,
	ToolCallEntry,
	ViewPreview
} from './tool-call-helpers.js';
import { parseListRowsResult, parseStatsResult } from './tool-call-helpers.js';
import { appendTextPart } from './tool-call-helpers.js';
import { parseShowDocuments, parseViewPreview } from './ui-tools.js';

/**
 * A reconstructed UI turn — either a user message or an agent segment whose
 * body is an ordered list of parts (text runs and tool-call bars) rendered in
 * flow order. One stored turn can produce multiple agent segments
 * (assistant → tool result → assistant continuation); each assistant message
 * becomes one segment.
 */
export type UiTurn =
	{ kind: 'user'; content: string } | { kind: 'agent'; parts: AgentPart[]; streaming: boolean };

/**
 * Reconstructs a list of UI turns from stored turn messages.
 *
 * Walks `request_messages` (user input) then `response_messages` (assistant
 * output + tool results + assistant continuations) in order. Each assistant
 * message becomes an agent segment carrying an ordered `parts` list: the
 * message's text (if any) first, followed by one `tool_call` part per
 * declared tool call. Tool-result messages are not rendered as standalone
 * bubbles — their content is surfaced as the `result` of the tool call they
 * resolve (matched by `tool_call_id`).
 *
 * Within a single assistant message the provider streams content deltas before
 * tool-call deltas, so text-before-tools is the faithful flow order; that
 * ordering is what `parts` encodes. Across messages, the `response_messages`
 * array order is the flow order.
 *
 * @example
 * ```ts
 * const turns = reconstructTurns(
 *   [{ role: 'user', content: 'hi' }],
 *   [
 *     { role: 'assistant', content: 'calling echo', tool_calls: [{ id: 'tc1', name: 'echo', arguments: '{}' }] },
 *     { role: 'tool', tool_call_id: 'tc1', name: 'echo', content: 'ok' },
 *     { role: 'assistant', content: 'done' },
 *   ],
 * );
 * // → [{ kind: 'user', content: 'hi' },
 * //    { kind: 'agent', parts: [
 * //        { type: 'reasoning', content: 'the caller wants a greeting' },
 * //        { type: 'text', content: 'calling echo' },
 * //        { type: 'tool_call', toolCall: { name: 'echo', result: 'ok', status: 'ok' } }
 * //      ], streaming: false },
 * //    { kind: 'agent', parts: [{ type: 'text', content: 'done' }], streaming: false }]
 * ```
 */
export function reconstructTurns(
	requestMessages: AgentMessage[],
	responseMessages: AgentMessage[],
	canceled = false
): UiTurn[] {
	const out: UiTurn[] = [];

	// User input — emit one user turn per user message (typically just one).
	for (const msg of requestMessages) {
		if (msg.role === 'user' && msg.content) {
			out.push({ kind: 'user', content: msg.content });
		}
	}

	// Index tool-result messages by tool_call_id so we can look up the result
	// when rendering the assistant message that declared the tool call.
	const toolResults = new Map<string, AgentMessage>();
	for (const msg of responseMessages) {
		if (msg.role === 'tool' && msg.tool_call_id) {
			toolResults.set(msg.tool_call_id, msg);
		}
	}

	for (const msg of responseMessages) {
		if (msg.role !== 'assistant') continue;

		const parts: AgentPart[] = [];
		// Reasoning is emitted by the provider before the visible text within
		// one assistant message, so it leads the part list when present.
		if (msg.reasoning) {
			parts.push({ type: 'reasoning', content: msg.reasoning });
		}
		// Text is streamed before tool-call deltas within one assistant message,
		// so it leads the part list.
		if (msg.content) {
			parts.push({ type: 'text', content: msg.content });
		}
		for (const tc of msg.tool_calls ?? []) {
			const resultMsg = toolResults.get(tc.id);
			const failed = isFailedToolResult(resultMsg?.content);
			if (tc.name === 'preview_view') {
				// UI tool — rebuild the preview card from the persisted arguments
				// so historical sessions keep showing the preview.
				const status = failed ? 'error' : 'ok';
				const preview: ViewPreview = { spec: parseViewPreview(tc.arguments), status };
				parts.push({ type: 'preview', preview });
				continue;
			}
			if (tc.name === 'show_documents' && !failed) {
				// UI tool — same treatment as preview_view: spec from the
				// persisted arguments (narrowed to the ack's rendered ids).
				const spec = parseShowDocuments(tc.arguments, resultMsg?.content);
				if (spec) {
					parts.push({ type: 'documents', documents: { spec, status: 'ok' } });
					continue;
				}
			}
			if ((tc.name === 'list_documents' || tc.name === 'aggregate_documents') && !failed) {
				// Registry tools carry no arguments on the wire — the part
				// rebuilds from the persisted tool-result envelope instead.
				const part = workspaceResultPart(tc.name, resultMsg?.content);
				if (part) {
					parts.push(part);
					continue;
				}
			}
			parts.push({
				type: 'tool_call',
				toolCall: toolCallEntryFromRef(tc, resultMsg)
			});
		}

		// Skip assistant messages that carry no renderable content (e.g. an
		// empty placeholder) so we don't emit a header-only segment.
		if (parts.length === 0) continue;

		out.push({ kind: 'agent', parts, streaming: false });
	}

	// A cancelled turn persists its partial history (agent-cr keeps the tool
	// work), so the partial content renders above a marker that matches the
	// live-stream notice (`> Cancelled.`) appended in the streaming consumers.
	if (canceled && out.length > 0) {
		const last = out[out.length - 1];
		if (last && last.kind === 'agent') {
			out[out.length - 1] = {
				kind: 'agent',
				parts: appendTextPart(last.parts, '\n\n> Cancelled.'),
				streaming: false
			};
		}
	}

	return out;
}

/**
 * Builds a `rows` / `stats` part from a persisted workspace registry-tool
 * result, mirroring the live-stream transform in `applyChunkToParts`. The
 * two tools keep no persisted `arguments` (only UI tools carry them), so
 * replay rebuilds from the tool-result envelope. Returns `null` when the
 * result is missing or unparseable — the caller falls back to the plain
 * tool-call bar.
 */
function workspaceResultPart(name: string, resultJson: string | undefined): AgentPart | null {
	if (name === 'list_documents') {
		const rows: ListRows | null = parseListRowsResult(resultJson);
		return rows ? { type: 'rows', rows } : null;
	}
	if (name === 'aggregate_documents') {
		const stats: Stats | null = parseStatsResult(resultJson);
		return stats ? { type: 'stats', stats } : null;
	}
	return null;
}

/**
 * A failed tool result reaches the transcript in two shapes: the backend
 * error prefix, or a JSON envelope that starts with `{"ok":false` — the
 * registry and UI tools report failure through that envelope.
 */
function isFailedToolResult(content: string | undefined): boolean {
	if (!content) return false;
	return content.startsWith('Error executing tool') || content.startsWith('{"ok":false');
}

function toolCallEntryFromRef(ref: ToolCallRef, resultMsg?: AgentMessage): ToolCallEntry {
	const detail = parseArgsDetail(ref.arguments);
	let result: string | undefined;
	let status: 'running' | 'ok' | 'error' = 'ok';

	if (resultMsg) {
		const content = resultMsg.content ?? '';
		if (isFailedToolResult(content)) {
			status = 'error';
		}
		result = content;
	}

	return {
		name: ref.name,
		detail,
		result,
		status
	};
}

/**
 * Renders tool-call arguments as a short `key=value, key=value` string,
 * mirroring `Assistant::Stream::Session::ToolTraceHandler#parse_args_detail`
 * on the backend. Returns `undefined` when args are empty or invalid JSON.
 */
function parseArgsDetail(argsJson?: string): string | undefined {
	if (!argsJson) return undefined;
	try {
		const parsed = JSON.parse(argsJson) as unknown;
		if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) return undefined;
		const obj = parsed as Record<string, unknown>;
		const entries = Object.entries(obj);
		if (entries.length === 0) return undefined;
		return entries
			.map(([k, v]) => `${k}=${typeof v === 'string' ? v : JSON.stringify(v)}`)
			.join(', ');
	} catch {
		return undefined;
	}
}
