// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { ToolCallStatus } from '../types.js';

/**
 * Scripted chunk emitted by the mock during a streamed turn.
 *
 * Each step is delivered with the `chunk` SSE event:
 * - `content` / `reasoning` steps push `text` tokens to the assistant bubble.
 *   `text` is emitted as a single chunk (the mock does not split it further);
 *   the story can choose to reveal sub-token by sub-token if needed.
 * - `tool_call` steps drive a `ToolCallBar`. A step with `status:"running"` is
 *   emitted first; a later step with the same `name` and `status:"ok"|"error"`
 *   resolves it. The mock emits "running" then the matching "ok"/"error"
 *   sequentially, matching what the real backend will do once
 *   `drain_stream` forwards `chunk.tool_call?` chunks.
 */
export type ScriptedChunk =
	| { kind: 'content'; text: string; delayMs?: number }
	| { kind: 'reasoning'; text: string; delayMs?: number }
	| {
			kind: 'tool_call';
			name: string;
			detail?: string;
			result?: string;
			status: ToolCallStatus;
			/** Raw JSON arguments — mirrors the `arguments` field the backend
			 * forwards for UI tools (`ui-tools.ts`). Needed so preview scripts
			 * can drive the `ViewPreviewCard`. */
			arguments?: string;
			delayMs?: number;
	  };

/** Terminal outcome the mock should report via the `done` / `error` event. */
export type ScriptedOutcome =
	| { kind: 'done'; finish_reason: string }
	| { kind: 'error'; message: string }
	| {
			/** The turn ends at the agent's tool-call iteration cap. The mock
			 * emits the normal `error` SSE event with the message, then completes
			 * the row with status `capped` and keeps the streamed exchange as the
			 * persisted partial. */
			kind: 'capped';
			message?: string;
	  }
	| { kind: 'cancelled' };

/**
 * A scripted turn — the mock's answer to one `streamAsk` invocation.
 *
 * The mock walks `chunks` in order, respecting each chunk's optional
 * `delayMs`, then emits one terminal {@link ScriptedOutcome}. If the caller
 * cancels mid-stream (via `MockAssistantDriver.cancel`), the mock stops after
 * the next delay check, emits `cancelled`, and ignores the rest of the script.
 */
export interface AssistantScript {
	/**
	 * Predicate that decides whether this script handles a given message.
	 * The mock tries scripts in order; the first match wins. If none match,
	 * the mock falls back to a canned «no script matched» error turn.
	 */
	match: (content: string, context: Record<string, unknown>) => boolean;
	/** Ordered chunks to stream before the terminal event. */
	chunks: ScriptedChunk[];
	/** Final event for this turn. */
	outcome: ScriptedOutcome;
	/** Synthetic `Usage` to persist with the turn (default zero usage). */
	usage?: { prompt_tokens: number; completion_tokens: number; total_tokens: number };
}

const NO_DELAY = 30;
const TOKEN_DELAY = 35;

/**
 * Splits a string into word-sized chunks so a story can reveal prose
 * token-by-token without writing the slicing inline. Returns chunks whose
 * `text` includes the trailing whitespace of each word.
 */
export function wordChunks(text: string, delayMs: number = TOKEN_DELAY): ScriptedChunk[] {
	const parts = text.match(/\S+\s*/g) ?? [];
	return parts.map((text) => ({ kind: 'content' as const, text, delayMs }));
}

/**
 * Word-sized `reasoning` chunks, mirroring {@link wordChunks} for the
 * thought-block demo. Lets a story reveal the model's thinking token-by-token.
 */
export function reasoningChunks(text: string, delayMs: number = TOKEN_DELAY): ScriptedChunk[] {
	const parts = text.match(/\S+\s*/g) ?? [];
	return parts.map((text) => ({ kind: 'reasoning' as const, text, delayMs }));
}

/**
 * Collapses every run of consecutive `content` chunks into one chunk, and
 * leaves `tool_call` and `reasoning` chunks in place.
 *
 * The word-by-word defaults are demo fidelity for the Storybook UI, but a
 * story `play` pays one thread re-render per chunk, so a full workspace
 * turn (~50 chunks) is CPU-bound and can outrun the per-test timeout on a
 * slow runner. The collapsed script renders the same text and drives the
 * same tool sequence at a fraction of the render cost. Use it as the first
 * script of the driver a play runs against:
 *
 * ```ts
 * const driver = new MockAssistantDriver([collapseContentChunks(workspaceScript), ...defaultScripts]);
 * ```
 */
export function collapseContentChunks(script: AssistantScript): AssistantScript {
	const chunks: ScriptedChunk[] = [];
	let pendingText = '';
	const flush = () => {
		if (pendingText !== '') {
			chunks.push({ kind: 'content', text: pendingText });
			pendingText = '';
		}
	};
	for (const chunk of script.chunks) {
		if (chunk.kind === 'content') {
			pendingText += chunk.text;
		} else {
			flush();
			chunks.push(chunk);
		}
	}
	flush();
	return { ...script, chunks };
}

// ── Canned scripts ───────────────────────────────────────────────────────

/**
 * Document ids the workspace fixture script shows through `show_documents`
 * and navigates to. Exported so stories can assert against the same ids.
 */
export const workspaceFixtureDocumentIds = [
	'core.doc_ws_aurora',
	'core.doc_ws_northwind',
	'core.doc_ws_cascade'
];

/**
 * Display names of the workspace fixture documents — exported alongside
 * {@link workspaceFixtureDocumentIds} so stories can assert the resolved
 * labels the renderers surface.
 */
export const workspaceFixtureNames = [
	'Aurora Print Studio',
	'Northwind Supply Co',
	'Cascade Coffee Roasters'
];

/**
 * Workspace fixture script — one full turn of the main-application
 * assistant, driving the sequence the dock is built around:
 * `list_documents` (registry tool) → `show_documents` cards (UI tool with
 * forwarded `arguments`) → `navigate` (UI tool) → `aggregate_documents`
 * (registry tool, money per-currency bag).
 *
 * Matches every message in a workspace conversation (`context.kind ===
 * 'workspace'`), so the dock stories and offline dev run the same scripted
 * sequence the phase-7 renderers consume. Registered first in
 * {@link defaultScripts} so it wins over the content-matched builder
 * scripts for workspace conversations.
 */
export const workspaceScript: AssistantScript = {
	match: (_content, ctx) => ctx['kind'] === 'workspace',
	chunks: [
		...wordChunks('Let me pull up the active customers first. '),
		{
			kind: 'tool_call',
			name: 'list_documents',
			detail: 'domain=crm, doctype=Customer, filters={"status": "active"}',
			status: 'running',
			delayMs: NO_DELAY
		},
		{
			kind: 'tool_call',
			name: 'list_documents',
			status: 'ok',
			// Same envelope the `list_documents` registry callback answers with
			// (`Read.list_result_payload`): one `{data, meta}` item per row,
			// the display fields riding on `meta`.
			result: JSON.stringify({
				ok: true,
				data: {
					data: workspaceFixtureDocumentIds.map((id, i) => ({
						data: { name: workspaceFixtureNames[i], status: 'active' },
						meta: {
							id,
							domain: 'crm',
							doc_type: 'Customer',
							mid: id,
							version: 1,
							created_at: '2026-03-17T09:00:00Z',
							updated_at: '2026-03-17T09:00:00Z',
							display_name: workspaceFixtureNames[i]
						}
					})),
					meta: { total: 3, page: 1, items: 3, truncated: false, next_cursor: null }
				}
			}),
			delayMs: NO_DELAY
		},
		...wordChunks('Here are the three I found — showing them as cards. '),
		{
			kind: 'tool_call',
			name: 'show_documents',
			detail: 'domain=crm, doctype=Customer, ids=[3]',
			arguments: JSON.stringify({
				domain: 'crm',
				doctype: 'Customer',
				ids: workspaceFixtureDocumentIds,
				display: 'card'
			}),
			status: 'running',
			delayMs: NO_DELAY
		},
		{
			kind: 'tool_call',
			name: 'show_documents',
			status: 'ok',
			arguments: JSON.stringify({
				domain: 'crm',
				doctype: 'Customer',
				ids: workspaceFixtureDocumentIds,
				display: 'card'
			}),
			result: JSON.stringify({
				ok: true,
				data: {
					rendered: workspaceFixtureDocumentIds,
					skipped: [],
					display: 'card',
					domain: 'crm',
					doctype: 'Customer'
				}
			}),
			delayMs: NO_DELAY
		},
		...wordChunks('I will open the first one for you. '),
		{
			kind: 'tool_call',
			name: 'navigate',
			detail: 'target=document, domain=crm, doctype=Customer',
			arguments: JSON.stringify({
				target: 'document',
				domain: 'crm',
				doctype: 'Customer',
				id: workspaceFixtureDocumentIds[0]
			}),
			status: 'running',
			delayMs: NO_DELAY
		},
		{
			kind: 'tool_call',
			name: 'navigate',
			status: 'ok',
			arguments: JSON.stringify({
				target: 'document',
				domain: 'crm',
				doctype: 'Customer',
				id: workspaceFixtureDocumentIds[0]
			}),
			result: JSON.stringify({
				ok: true,
				data: {
					navigated: true,
					target: 'document',
					domain: 'crm',
					doctype: 'Customer',
					id: workspaceFixtureDocumentIds[0]
				}
			}),
			delayMs: NO_DELAY
		},
		...wordChunks('And the revenue picture across the three. '),
		{
			kind: 'tool_call',
			name: 'aggregate_documents',
			detail: 'domain=crm, doctype=Customer, aggregate=sum, field=revenue',
			status: 'running',
			delayMs: NO_DELAY
		},
		{
			kind: 'tool_call',
			name: 'aggregate_documents',
			status: 'ok',
			// Same envelope the `aggregate_documents` registry callback answers
			// with (`Read.aggregate_result_payload`): the money field returns
			// the per-currency bag as `value`, with the contributing-row count.
			result: JSON.stringify({
				ok: true,
				data: {
					aggregate: 'sum',
					field: 'revenue',
					value: { USD: '184250.00', EUR: '42980.00' },
					count: 3
				}
			}),
			delayMs: NO_DELAY
		},
		...wordChunks('The cards and the totals are above — anything else?')
	],
	outcome: { kind: 'done', finish_reason: 'stop' },
	usage: { prompt_tokens: 210, completion_tokens: 96, total_tokens: 306 }
};

/**
 * Default logistics-domain script — carries the prose + tool call + mermaid
 * diagram that the ChatThread story used to hard-code inline. Wired so a
 * message mentioning "shipment" or "logistics" routes to it.
 */
export const logisticsScript: AssistantScript = {
	match: (content, _ctx) => /logistics|shipment/i.test(content),
	chunks: [
		{
			kind: 'tool_call',
			name: 'inspect_domain',
			detail: 'inspecting domain crm — found Customer, Contact, Deal',
			result: '6 doctypes',
			status: 'running',
			delayMs: NO_DELAY
		},
		{
			kind: 'tool_call',
			name: 'inspect_domain',
			status: 'ok',
			delayMs: NO_DELAY
		},
		...reasoningChunks(
			'The user wants shipments in a new logistics domain. Shipment is the natural aggregate root; addresses are embedded objects, status is an enum, and the customer is a cross-domain reference into crm.Customer.'
		),
		...wordChunks("I'll start a `logistics` domain with `Shipment` as an aggregate root. "),
		...wordChunks('The two addresses fit as **embedded objects**, status maps to an `enum`, '),
		...wordChunks('and the customer becomes a cross-domain reference into `crm.Customer`.\n\n'),
		...wordChunks('First draft:\n\n'),
		...wordChunks('- `reference_no` — booking reference\n'),
		...wordChunks('- `status` — enum\n'),
		...wordChunks('- `customer_id` — reference to `crm.Customer`\n\n'),
		...wordChunks('Lifecycle:\n\n'),
		{
			kind: 'content',
			text: '```mermaid\nflowchart LR\n  A[booked] --> B[in_transit]\n  B --> C[delivered]\n```\n',
			delayMs: TOKEN_DELAY
		}
	],
	outcome: { kind: 'done', finish_reason: 'stop' },
	usage: { prompt_tokens: 120, completion_tokens: 88, total_tokens: 208 }
};

/**
 * Error-path script — exercises the `error` terminal event and an error
 * `ToolCallBar`. Triggered by sending a message containing the word "fail".
 */
export const errorScript: AssistantScript = {
	match: (content, _ctx) => /\bfail\b/i.test(content),
	chunks: [
		{
			kind: 'tool_call',
			name: 'apply_mutation',
			detail: 'create doctype logistics.Shipment',
			result: 'validation failed',
			status: 'running',
			delayMs: NO_DELAY
		},
		{
			kind: 'tool_call',
			name: 'apply_mutation',
			status: 'error',
			delayMs: NO_DELAY
		}
	],
	outcome: { kind: 'error', message: 'Mutation rejected: validation failed' },
	usage: { prompt_tokens: 40, completion_tokens: 0, total_tokens: 40 }
};

/**
 * Long-running script for cancel demos — emits chunks slowly so a click on
 * "Cancel" lands before the `done` event. Triggered by a message containing
 * "cancel".
 */
export const longRunningScript: AssistantScript = {
	match: (content, _ctx) => /\bcancel\b/i.test(content),
	chunks: [
		{ kind: 'content', text: 'Working on it… ', delayMs: 100 },
		{ kind: 'content', text: 'step one done. ', delayMs: 400 },
		{ kind: 'content', text: 'step two done. ', delayMs: 400 },
		{ kind: 'content', text: 'finishing up.', delayMs: 400 }
	],
	outcome: { kind: 'done', finish_reason: 'stop' },
	usage: { prompt_tokens: 20, completion_tokens: 12, total_tokens: 32 }
};

/**
 * Document DVT preview script — exercises the `preview_view` UI tool. The
 * resolving chunk carries the raw `arguments` the card parses. Triggered by
 * a message containing "preview".
 */
export const previewDocumentScript: AssistantScript = {
	match: (content, _ctx) => /\bpreview\b/i.test(content),
	chunks: [
		...wordChunks('Here is what the customer show view would look like: '),
		{
			kind: 'tool_call',
			name: 'preview_view',
			status: 'running',
			delayMs: NO_DELAY
		},
		{
			kind: 'tool_call',
			name: 'preview_view',
			status: 'ok',
			arguments: JSON.stringify({
				kind: 'document',
				title: 'Customer show view',
				template: {
					type: 'col',
					children: [
						{
							type: 'section',
							label: 'Identity',
							children: [
								{ type: 'field', label: 'Name', value: '$name' },
								{ type: 'field', label: 'Email', value: '$email' },
								{ type: 'field', label: 'Phone', value: '$phone' }
							]
						},
						{
							type: 'section',
							label: 'Commercial',
							children: [
								{ type: 'field', label: 'Annual revenue', value: '$revenue' },
								{ type: 'field', label: 'Status', value: '$status' }
							]
						}
					]
				},
				sample_data: {
					name: 'Aurora Print Studio',
					revenue: { value: '184000.00', currency: 'USD' }
				}
			}),
			delayMs: NO_DELAY
		},
		...wordChunks(
			'The revenue capsule and the active status chip come from the declared field types.'
		)
	],
	outcome: { kind: 'done', finish_reason: 'stop' },
	usage: { prompt_tokens: 60, completion_tokens: 40, total_tokens: 100 }
};

/**
 * Collection surface preview script — a `preview_view` call with
 * `kind:'collection'`, rendered as a fake table. Triggered by a message
 * containing "table preview".
 */
export const previewCollectionScript: AssistantScript = {
	match: (content, _ctx) => /table preview/i.test(content),
	chunks: [
		...wordChunks('Here is the listing surface with fake rows: '),
		{
			kind: 'tool_call',
			name: 'preview_view',
			status: 'running',
			delayMs: NO_DELAY
		},
		{
			kind: 'tool_call',
			name: 'preview_view',
			status: 'ok',
			arguments: JSON.stringify({
				kind: 'collection',
				surface: 'table',
				title: 'Shipments — table',
				config: {
					columns: [
						{ key: 'reference_no', label: 'Reference', width: '140px' },
						{ key: 'status' },
						{ key: 'total_amount', label: 'Total' },
						{ key: 'pickup_date', label: 'Pickup' }
					]
				},
				sample_data: { reference_no: 'SHP-2026-0042' }
			}),
			delayMs: NO_DELAY
		}
	],
	outcome: { kind: 'done', finish_reason: 'stop' },
	usage: { prompt_tokens: 40, completion_tokens: 20, total_tokens: 60 }
};

/**
 * Navigation script — exercises the `go_to_page` UI tool. The frontend
 * navigates when the resolving chunk arrives (live stream only). Triggered
 * by a message containing "go to".
 */
export const navigateScript: AssistantScript = {
	match: (content, _ctx) => /go to the/i.test(content),
	chunks: [
		...wordChunks('Bringing you to the doctype editor. '),
		{
			kind: 'tool_call',
			name: 'go_to_page',
			detail: 'page=doctype',
			status: 'running',
			delayMs: NO_DELAY
		},
		{
			kind: 'tool_call',
			name: 'go_to_page',
			status: 'ok',
			arguments: JSON.stringify({ page: 'doctype', doctype_id: 'logistics.Shipment' }),
			delayMs: NO_DELAY
		},
		...wordChunks('The Shipment editor is open — fields tab.')
	],
	outcome: { kind: 'done', finish_reason: 'stop' },
	usage: { prompt_tokens: 30, completion_tokens: 15, total_tokens: 45 }
};

/** Default scripts shipped by the mock. Callers can prepend their own.
 * The workspace script comes first so its context match wins over the
 * content-matched builder scripts. */
export const defaultScripts: AssistantScript[] = [
	workspaceScript,
	logisticsScript,
	previewDocumentScript,
	previewCollectionScript,
	navigateScript,
	errorScript,
	longRunningScript
];
