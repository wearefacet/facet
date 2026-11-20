// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { StreamChunk, ToolCallStatus } from '../driver/types.js';
import {
	parseShowDocuments,
	parseViewPreview,
	type ShowDocumentsArgs,
	type ViewPreviewSpec
} from './ui-tools.js';

/**
 * A tool call rendered by {@link ToolCallBar} — the per-turn working state
 * the streaming consumer mutates as `chunk` events with `kind:"tool_call"`
 * arrive. Kept as a separate type (not in `types.ts`) because it is a
 * view-model, not a backend wire shape: it's the merge of "running" + "ok"
 * halves of the same tool call.
 */
export interface ToolCallEntry {
	name: string;
	detail?: string;
	result?: string;
	status: ToolCallStatus;
}

/**
 * One ordered block of an agent turn, rendered in flow order inside
 * {@link ChatTurnPanel}. A turn is a sequence of text runs interleaved with
 * reasoning blocks and tool-call bars exactly as they were emitted on the
 * stream — so a turn that streams `reasoning → text → tool_call → text`
 * renders in that order, not as a single text bubble after the tool bar.
 *
 * The `preview` variant carries a `preview_view` UI-tool call rendered by
 * `ViewPreviewCard` — the card *is* the tool-call UI, so these calls do not
 * also render a `ToolCallBar`.
 *
 * The workspace variants render the registry-tool results as surfaces:
 * `rows` (a `list_documents` page as compact document rows), `stats` (an
 * `aggregate_documents` result as metric tiles), and `documents` (a
 * `show_documents` call as a card grid or inline list). The display data is
 * re-resolved by the renderer from the data source; the part carries
 * document identity only. Unparseable payloads fall back to a `tool_call`
 * part so the raw trace stays visible.
 */
export interface ViewPreview {
	spec: ViewPreviewSpec | null;
	status: ToolCallStatus;
}

/** Document identity carried by a `rows` or `documents` part — enough for
 * the renderer to resolve the record itself (`{domain}.{doctype}.{id}`). */
export interface DocumentRow {
	domain: string;
	doctype: string;
	id: string;
}

/** A resolved `rows` part: the page items of a `list_documents` call.
 * `total` is the capped match count from the payload's `meta`. */
export interface ListRows {
	rows: DocumentRow[];
	total?: number;
}

/** A resolved `documents` part: parsed `show_documents` arguments (narrowed
 * to the ack's `rendered` ids) plus the call status. `spec: null` with a
 * terminal status marks a payload that failed validation. */
export interface ShowDocuments {
	spec: ShowDocumentsArgs | null;
	status: ToolCallStatus;
}

/** Aggregate kinds `aggregate_documents` accepts. */
export type AggregateKind = 'count' | 'sum' | 'avg' | 'min' | 'max';

/** A resolved `stats` part: one `aggregate_documents` run. `value` is a
 * number, a string (decimal/duration), a per-currency bag for `money`
 * fields, or `null` on an empty set. `count` is the contributing-row count. */
export interface Stats {
	aggregate: AggregateKind;
	field?: string;
	value: number | string | Record<string, string | number> | null;
	count: number | null;
}

export type AgentPart =
	| { type: 'text'; content: string }
	| { type: 'reasoning'; content: string }
	| { type: 'tool_call'; toolCall: ToolCallEntry }
	| { type: 'preview'; preview: ViewPreview }
	| { type: 'rows'; rows: ListRows }
	| { type: 'stats'; stats: Stats }
	| { type: 'documents'; documents: ShowDocuments };

/**
 * Applies a streamed `chunk` event to an ordered list of agent parts,
 * preserving flow order.
 *
 * Returns a new array (immutable update for Svelte reactivity):
 * - `content` chunks append to the trailing text part if the last part is
 *   text, otherwise start a new text part — so contiguous text stays one
 *   bubble and text after a tool call becomes a new bubble.
 * - `reasoning` chunks append to the trailing reasoning part if the last
 *   part is reasoning, otherwise start a new reasoning part — so contiguous
 *   thinking stays one thought block.
 * - a `tool_call` chunk with status `running` pushes a new `tool_call` part
 *   (same tool called twice → two bars).
 * - a `tool_call` chunk with a terminal status (`ok` / `error`) resolves the
 *   nearest preceding same-name `running` part **in place** (preserving its
 *   position in the flow), merging `detail`/`result` from the running half
 *   when the resolving chunk omits them. If no running half is found, a
 *   standalone resolved part is appended.
 *
 * Between a call's `running` and `ok`/`error` no content chunks arrive (the
 * `ToolTraceHandler` emits both around the synchronous callback), so the
 * in-place resolution never spans across interleaved text.
 *
 * Designed to be called inside the `for await (const ev of streamAsk(…))`
 * loop in components that use `ChatTurnPanel`.
 */
export function applyChunkToParts(current: AgentPart[], chunk: StreamChunk): AgentPart[] {
	if (chunk.kind === 'content') {
		return appendTextPart(current, chunk.text);
	}
	if (chunk.kind === 'reasoning') {
		return appendReasoningPart(current, chunk.text);
	}
	if (chunk.kind !== 'tool_call') return current;

	const next = [...current];

	// UI tool: `preview_view` renders as a preview card, not a tool bar.
	if (chunk.name === 'preview_view') {
		return applyPreviewChunk(next, chunk);
	}

	// Workspace tools: a resolved `list_documents` / `aggregate_documents`
	// result that parses becomes a rows / stats surface in place of the tool
	// bar; a `show_documents` call renders as a documents part (no bar).
	if (chunk.name === 'list_documents' && chunk.status === 'ok') {
		const rows = parseListRowsResult(chunk.result);
		if (rows) return replaceRunningToolCall(next, chunk.name, { type: 'rows', rows });
		// Unparseable payload — fall through: the bar keeps the raw trace.
	}
	if (chunk.name === 'aggregate_documents' && chunk.status === 'ok') {
		const stats = parseStatsResult(chunk.result);
		if (stats) return replaceRunningToolCall(next, chunk.name, { type: 'stats', stats });
	}
	if (chunk.name === 'show_documents') {
		return applyShowDocumentsChunk(next, chunk);
	}

	if (chunk.status === 'running') {
		// Always start a new part — two sequential calls to `echo` render as
		// two distinct `ToolCallBar`s.
		next.push({
			type: 'tool_call',
			toolCall: {
				name: chunk.name,
				detail: chunk.detail,
				result: chunk.result,
				status: 'running'
			}
		});
		return next;
	}

	// Terminal status (`ok` / `error`): resolve the nearest preceding
	// same-name `running` part in place. Search from the end so concurrent
	// same-named calls pair with the most recent outstanding one.
	const idx = findLastRunningToolCall(next, chunk.name);
	const resolved: ToolCallEntry = {
		name: chunk.name,
		detail: chunk.detail,
		result: chunk.result,
		status: chunk.status
	};
	if (idx === -1) {
		next.push({ type: 'tool_call', toolCall: resolved });
	} else {
		const prev = next[idx];
		if (prev && prev.type === 'tool_call') {
			next[idx] = {
				type: 'tool_call',
				toolCall: {
					...resolved,
					detail: resolved.detail ?? prev.toolCall.detail,
					result: resolved.result ?? prev.toolCall.result
				}
			};
		}
	}
	return next;
}

/**
 * Appends raw text (e.g. error / cancelled notices that are not streamed as
 * `content` chunks) to the trailing text part, or starts a new text part.
 * Mirrors the text-accumulation rule of {@link applyChunkToParts} so a notice
 * caves onto the current bubble instead of opening a detached one.
 */
export function appendTextPart(current: AgentPart[], text: string): AgentPart[] {
	if (!text) return current;
	const next = [...current];
	const last = next[next.length - 1];
	if (last && last.type === 'text') {
		next[next.length - 1] = { type: 'text', content: last.content + text };
	} else {
		next.push({ type: 'text', content: text });
	}
	return next;
}

/**
 * Appends reasoning text to the trailing reasoning part, or starts a new
 * reasoning part. Mirrors the accumulation rule of {@link appendTextPart} so
 * contiguous thinking stays one thought block.
 */
export function appendReasoningPart(current: AgentPart[], text: string): AgentPart[] {
	if (!text) return current;
	const next = [...current];
	const last = next[next.length - 1];
	if (last && last.type === 'reasoning') {
		next[next.length - 1] = { type: 'reasoning', content: last.content + text };
	} else {
		next.push({ type: 'reasoning', content: text });
	}
	return next;
}

function findLastRunningToolCall(parts: AgentPart[], name: string): number {
	for (let i = parts.length - 1; i >= 0; i--) {
		const part = parts[i];
		if (
			part &&
			part.type === 'tool_call' &&
			part.toolCall.name === name &&
			part.toolCall.status === 'running'
		) {
			return i;
		}
	}
	return -1;
}

/** Applies a `preview_view` tool_call chunk to the part list: `running`
 * pushes a placeholder card, a terminal status resolves the nearest running
 * card in place with the parsed spec (same pairing rule as tool bars). */
function applyPreviewChunk(
	parts: AgentPart[],
	chunk: Extract<StreamChunk, { kind: 'tool_call' }>
): AgentPart[] {
	const next = [...parts];
	if (chunk.status === 'running') {
		next.push({ type: 'preview', preview: { spec: null, status: 'running' } });
		return next;
	}
	const spec = parseViewPreview(chunk.arguments);
	const idx = findLastRunningPreview(next);
	const resolved: ViewPreview = { spec, status: chunk.status };
	if (idx === -1) {
		next.push({ type: 'preview', preview: resolved });
	} else {
		next[idx] = { type: 'preview', preview: resolved };
	}
	return next;
}

function findLastRunningPreview(parts: AgentPart[]): number {
	for (let i = parts.length - 1; i >= 0; i--) {
		const part = parts[i];
		if (part && part.type === 'preview' && part.preview.status === 'running') return i;
	}
	return -1;
}

// ── Workspace tool seams ───────────────────────────────────────────────────
//
// The workspace assistant mounts the MCP registry tools (see
// `Assistant::Workspace::Registrar`). Their callbacks answer in the shared
// `Assistant::Tools` envelope — `{ok:true, data:…}` on success — carried as
// the resolving chunk's `result` string. The parsers below turn those
// payloads into display parts; anything they reject keeps the plain
// tool-call bar with the raw trace.

/** Parses the envelope a resolved `list_documents` chunk carries:
 * `{ok, data: {data: [{data, meta}], meta: {total, …}}}`. Each item's
 * `meta` holds the document identity (`id`, `domain`, `doc_type`).
 * Returns `null` for a non-ok, malformed, or item-less payload. */
export function parseListRowsResult(resultJson: string | undefined): ListRows | null {
	const envelope = parseToolEnvelope(resultJson);
	if (!envelope || envelope.ok !== true) return null;
	const data = envelope.data;
	if (!data || typeof data !== 'object' || Array.isArray(data)) return null;
	const items = data['data'];
	if (!Array.isArray(items) || items.length === 0) return null;

	const rows: DocumentRow[] = [];
	for (const item of items) {
		if (!item || typeof item !== 'object' || Array.isArray(item)) return null;
		const meta = (item as Record<string, unknown>)['meta'];
		if (!meta || typeof meta !== 'object' || Array.isArray(meta)) return null;
		const m = meta as Record<string, unknown>;
		const id = m['id'];
		const domain = m['domain'];
		const doctype = m['doc_type'];
		if (typeof id !== 'string' || id.length === 0) return null;
		if (typeof domain !== 'string' || domain.length === 0) return null;
		if (typeof doctype !== 'string' || doctype.length === 0) return null;
		rows.push({ domain, doctype, id });
	}

	const out: ListRows = { rows };
	const meta = data['meta'];
	if (meta && typeof meta === 'object' && !Array.isArray(meta)) {
		const total = (meta as Record<string, unknown>)['total'];
		if (typeof total === 'number') out.total = total;
	}
	return out;
}

const AGGREGATE_KINDS: readonly AggregateKind[] = ['count', 'sum', 'avg', 'min', 'max'];

/** Parses the envelope a resolved `aggregate_documents` chunk carries:
 * `{ok, data: {aggregate, value, count, field?}}`. `value` is a number or
 * string scalar, a per-currency bag for `money` fields, or `null` on an
 * empty set. Returns `null` for a non-ok or malformed payload. */
export function parseStatsResult(resultJson: string | undefined): Stats | null {
	const envelope = parseToolEnvelope(resultJson);
	if (!envelope || envelope.ok !== true) return null;
	const data = envelope.data;
	if (!data || typeof data !== 'object' || Array.isArray(data)) return null;

	const aggregate = data['aggregate'];
	if (typeof aggregate !== 'string' || !AGGREGATE_KINDS.includes(aggregate as AggregateKind)) {
		return null;
	}

	let value: Stats['value'] = null;
	const rawValue = data['value'];
	if (typeof rawValue === 'number' || typeof rawValue === 'string') {
		value = rawValue;
	} else if (rawValue && typeof rawValue === 'object' && !Array.isArray(rawValue)) {
		const bag: Record<string, string | number> = {};
		for (const [currency, amount] of Object.entries(rawValue)) {
			if (typeof amount !== 'string' && typeof amount !== 'number') return null;
			bag[currency] = amount;
		}
		value = bag;
	} else if (rawValue !== null && rawValue !== undefined) {
		return null;
	}

	const rawCount = data['count'];
	const count = typeof rawCount === 'number' ? rawCount : null;

	const out: Stats = { aggregate: aggregate as AggregateKind, value, count };
	const field = data['field'];
	if (typeof field === 'string' && field.length > 0) out.field = field;
	return out;
}

/** Parses a chunk's `result` string as the shared tool envelope. Returns
 * `null` for absent, malformed, or non-object JSON. */
function parseToolEnvelope(
	resultJson: string | undefined
): { ok: unknown; data: Record<string, unknown> | null } | null {
	if (!resultJson) return null;
	try {
		const parsed: unknown = JSON.parse(resultJson);
		if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) return null;
		const obj = parsed as Record<string, unknown>;
		const data = obj['data'];
		if (data === null || data === undefined) return { ok: obj['ok'], data: null };
		if (typeof data !== 'object' || Array.isArray(data)) return { ok: obj['ok'], data: null };
		return { ok: obj['ok'], data: data as Record<string, unknown> };
	} catch {
		return null;
	}
}

/** Replaces the nearest preceding same-name running tool-call part with the
 * given surface part (same pairing rule as tool bars). With no running half
 * outstanding, the surface appends — a resolved chunk always yields exactly
 * one part. */
function replaceRunningToolCall(parts: AgentPart[], name: string, part: AgentPart): AgentPart[] {
	const idx = findLastRunningToolCall(parts, name);
	const next = [...parts];
	if (idx === -1) {
		next.push(part);
	} else {
		next[idx] = part;
	}
	return next;
}

/** Applies a `show_documents` tool_call chunk to the part list: `running`
 * pushes a placeholder, a terminal status resolves the nearest running
 * placeholder in place with the parsed spec (same pairing rule as preview
 * cards). Arguments that fail validation fall back to a `tool_call` part —
 * the bar keeps the raw result trace. */
function applyShowDocumentsChunk(
	parts: AgentPart[],
	chunk: Extract<StreamChunk, { kind: 'tool_call' }>
): AgentPart[] {
	const next = [...parts];
	if (chunk.status === 'running') {
		next.push({ type: 'documents', documents: { spec: null, status: 'running' } });
		return next;
	}

	const spec = parseShowDocuments(chunk.arguments, chunk.result);
	const idx = findLastRunningDocumentsPart(next);

	if (chunk.status === 'ok' && !spec) {
		// Parse failure on success — render the fallback bar instead.
		const fallback: AgentPart = {
			type: 'tool_call',
			toolCall: { name: chunk.name, detail: chunk.detail, result: chunk.result, status: 'ok' }
		};
		if (idx === -1) next.push(fallback);
		else next[idx] = fallback;
		return next;
	}

	const resolved: ShowDocuments = { spec, status: chunk.status };
	if (idx === -1) {
		next.push({ type: 'documents', documents: resolved });
	} else {
		next[idx] = { type: 'documents', documents: resolved };
	}
	return next;
}

function findLastRunningDocumentsPart(parts: AgentPart[]): number {
	for (let i = parts.length - 1; i >= 0; i--) {
		const part = parts[i];
		if (part && part.type === 'documents' && part.documents.status === 'running') return i;
	}
	return -1;
}
