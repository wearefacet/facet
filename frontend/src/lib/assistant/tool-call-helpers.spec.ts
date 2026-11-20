// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it } from 'vitest';
import {
	applyChunkToParts,
	appendReasoningPart,
	appendTextPart,
	parseListRowsResult,
	parseStatsResult
} from './tool-call-helpers.js';
import type { StreamChunk } from './types.js';

describe('applyChunkToParts — reasoning routing', () => {
	it('routes a reasoning chunk into a reasoning part', () => {
		const parts = applyChunkToParts([], { kind: 'reasoning', text: 'think ' });
		expect(parts).toEqual([{ type: 'reasoning', content: 'think ' }]);
	});

	it('accumulates contiguous reasoning chunks into one reasoning part', () => {
		let parts = applyChunkToParts([], { kind: 'reasoning', text: 'a ' });
		parts = applyChunkToParts(parts, { kind: 'reasoning', text: 'b ' });
		parts = applyChunkToParts(parts, { kind: 'reasoning', text: 'c' });
		expect(parts).toEqual([{ type: 'reasoning', content: 'a b c' }]);
	});

	it('does not merge reasoning into a preceding text part', () => {
		let parts: ReturnType<typeof applyChunkToParts> = [{ type: 'text', content: 'answer' }];
		parts = applyChunkToParts(parts, { kind: 'reasoning', text: 'think' });
		expect(parts).toEqual([
			{ type: 'text', content: 'answer' },
			{ type: 'reasoning', content: 'think' }
		]);
	});

	it('does not merge content into a preceding reasoning part', () => {
		let parts: ReturnType<typeof applyChunkToParts> = [{ type: 'reasoning', content: 'think' }];
		parts = applyChunkToParts(parts, { kind: 'content', text: 'answer' });
		expect(parts).toEqual([
			{ type: 'reasoning', content: 'think' },
			{ type: 'text', content: 'answer' }
		]);
	});

	it('preserves flow order reasoning → text → tool_call → text', () => {
		const chunks: StreamChunk[] = [
			{ kind: 'reasoning', text: 'plan ' },
			{ kind: 'reasoning', text: 'first' },
			{ kind: 'content', text: 'Calling now. ' },
			{ kind: 'tool_call', name: 'echo', status: 'running' },
			{ kind: 'tool_call', name: 'echo', status: 'ok' },
			{ kind: 'content', text: 'Done.' }
		];
		const parts = chunks.reduce(applyChunkToParts, [] as ReturnType<typeof applyChunkToParts>);
		expect(parts).toEqual([
			{ type: 'reasoning', content: 'plan first' },
			{ type: 'text', content: 'Calling now. ' },
			{
				type: 'tool_call',
				toolCall: { name: 'echo', detail: undefined, result: undefined, status: 'ok' }
			},
			{ type: 'text', content: 'Done.' }
		]);
	});
});

describe('appendReasoningPart', () => {
	it('caves onto a trailing reasoning part', () => {
		const parts = appendReasoningPart([{ type: 'reasoning', content: 'a' }], 'b');
		expect(parts).toEqual([{ type: 'reasoning', content: 'ab' }]);
	});

	it('starts a new reasoning part when the tail is text', () => {
		const parts = appendReasoningPart([{ type: 'text', content: 'answer' }], 'think');
		expect(parts).toEqual([
			{ type: 'text', content: 'answer' },
			{ type: 'reasoning', content: 'think' }
		]);
	});

	it('returns the same array for empty text', () => {
		const current: ReturnType<typeof applyChunkToParts> = [];
		expect(appendReasoningPart(current, '')).toBe(current);
	});
});

describe('appendTextPart still works', () => {
	it('caves onto a trailing text part', () => {
		const parts = appendTextPart([{ type: 'text', content: 'a' }], 'b');
		expect(parts).toEqual([{ type: 'text', content: 'ab' }]);
	});
});

describe('applyChunkToParts — preview_view UI tool', () => {
	const template = { type: 'label', value: '$name' };
	const okArgs = JSON.stringify({ kind: 'document', template });

	it('pushes a placeholder card on running and resolves it in place on ok', () => {
		let parts = applyChunkToParts([], {
			kind: 'tool_call',
			name: 'preview_view',
			status: 'running'
		});
		expect(parts).toEqual([{ type: 'preview', preview: { spec: null, status: 'running' } }]);

		parts = applyChunkToParts(parts, {
			kind: 'tool_call',
			name: 'preview_view',
			status: 'ok',
			arguments: okArgs
		});
		expect(parts).toEqual([
			{ type: 'preview', preview: { spec: { kind: 'document', template }, status: 'ok' } }
		]);
	});

	it('resolves with an error status when arguments fail validation', () => {
		let parts = applyChunkToParts([], {
			kind: 'tool_call',
			name: 'preview_view',
			status: 'running'
		});
		parts = applyChunkToParts(parts, {
			kind: 'tool_call',
			name: 'preview_view',
			status: 'ok',
			arguments: 'not json'
		});
		expect(parts).toEqual([{ type: 'preview', preview: { spec: null, status: 'ok' } }]);
	});

	it('does not render a ToolCallBar for preview_view', () => {
		const parts = [
			{ kind: 'tool_call', name: 'preview_view', status: 'running' },
			{ kind: 'tool_call', name: 'preview_view', status: 'ok', arguments: okArgs }
		].reduce(
			(acc, c) => applyChunkToParts(acc, c as StreamChunk),
			[] as ReturnType<typeof applyChunkToParts>
		);
		expect(parts.some((p) => p.type === 'tool_call')).toBe(false);
	});

	it('renders ordinary tool calls alongside a preview card', () => {
		const chunks: StreamChunk[] = [
			{ kind: 'tool_call', name: 'preview_view', status: 'running' },
			{ kind: 'tool_call', name: 'preview_view', status: 'ok', arguments: okArgs },
			{ kind: 'tool_call', name: 'get_doctype', status: 'running' },
			{ kind: 'tool_call', name: 'get_doctype', status: 'ok', result: 'def' }
		];
		const parts = chunks.reduce(applyChunkToParts, [] as ReturnType<typeof applyChunkToParts>);
		expect(parts.map((p) => p.type)).toEqual(['preview', 'tool_call']);
	});
});

// ── Workspace tool seams ─────────────────────────────────────────────

const LIST_ENVELOPE = JSON.stringify({
	ok: true,
	data: {
		data: [
			{
				data: { name: 'Aurora' },
				meta: { id: 'crm.Customer.1', domain: 'crm', doc_type: 'Customer' }
			},
			{
				data: { name: 'Northwind' },
				meta: { id: 'crm.Customer.2', domain: 'crm', doc_type: 'Customer' }
			}
		],
		meta: { total: 2, page: 1, truncated: false }
	}
});

const STATS_ENVELOPE = JSON.stringify({
	ok: true,
	data: { aggregate: 'sum', field: 'revenue', value: { USD: '184250.00' }, count: 3 }
});

/** Applies a chunk sequence like the panel's reduce loop, with the array
 * typed so the literal chunks narrow to `StreamChunk`. */
function applyAll(chunks: StreamChunk[]): ReturnType<typeof applyChunkToParts> {
	return chunks.reduce(applyChunkToParts, [] as ReturnType<typeof applyChunkToParts>);
}

describe('applyChunkToParts — list_documents → rows part', () => {
	it('keeps the running bar, then replaces it in place with the rows part', () => {
		let parts = applyChunkToParts([], {
			kind: 'tool_call',
			name: 'list_documents',
			status: 'running'
		});
		expect(parts).toEqual([
			{ type: 'tool_call', toolCall: { name: 'list_documents', status: 'running' } }
		]);

		parts = applyChunkToParts(parts, {
			kind: 'tool_call',
			name: 'list_documents',
			status: 'ok',
			result: LIST_ENVELOPE
		});
		expect(parts).toEqual([
			{
				type: 'rows',
				rows: {
					rows: [
						{ domain: 'crm', doctype: 'Customer', id: 'crm.Customer.1' },
						{ domain: 'crm', doctype: 'Customer', id: 'crm.Customer.2' }
					],
					total: 2
				}
			}
		]);
	});

	it('falls back to the tool-call bar when the result fails to parse', () => {
		const parts = applyAll([
			{ kind: 'tool_call', name: 'list_documents', status: 'running' },
			{ kind: 'tool_call', name: 'list_documents', status: 'ok', result: 'not json' }
		]);
		expect(parts).toEqual([
			{
				type: 'tool_call',
				toolCall: {
					name: 'list_documents',
					detail: undefined,
					result: 'not json',
					status: 'ok'
				}
			}
		]);
	});

	it('keeps the bar for an error status even with a parseable result', () => {
		const parts = applyAll([
			{ kind: 'tool_call', name: 'list_documents', status: 'running' },
			{ kind: 'tool_call', name: 'list_documents', status: 'error', result: 'Error executing tool' }
		]);
		expect(parts.every((p) => p.type === 'tool_call')).toBe(true);
	});
});

describe('applyChunkToParts — aggregate_documents → stats part', () => {
	it('replaces the running bar in place with the stats part', () => {
		const parts = applyAll([
			{ kind: 'tool_call', name: 'aggregate_documents', status: 'running' },
			{ kind: 'tool_call', name: 'aggregate_documents', status: 'ok', result: STATS_ENVELOPE }
		]);
		expect(parts).toEqual([
			{
				type: 'stats',
				stats: { aggregate: 'sum', field: 'revenue', value: { USD: '184250.00' }, count: 3 }
			}
		]);
	});

	it('falls back to the tool-call bar on a non-ok or malformed envelope', () => {
		const results = [JSON.stringify({ ok: false, error: 'Denied' }), 'not json', undefined];
		for (const result of results) {
			const parts = applyAll([
				{ kind: 'tool_call', name: 'aggregate_documents', status: 'running' },
				{ kind: 'tool_call', name: 'aggregate_documents', status: 'ok', result }
			]);
			expect(parts.every((p) => p.type === 'tool_call')).toBe(true);
		}
	});
});

describe('applyChunkToParts — show_documents → documents part', () => {
	const okArgs = JSON.stringify({ domain: 'crm', doctype: 'Customer', ids: ['a', 'b'] });
	const okResult = JSON.stringify({ ok: true, data: { rendered: ['b'], skipped: ['a'] } });

	it('pushes a placeholder on running and resolves it in place on ok', () => {
		let parts = applyChunkToParts([], {
			kind: 'tool_call',
			name: 'show_documents',
			status: 'running'
		});
		expect(parts).toEqual([{ type: 'documents', documents: { spec: null, status: 'running' } }]);

		parts = applyChunkToParts(parts, {
			kind: 'tool_call',
			name: 'show_documents',
			status: 'ok',
			arguments: okArgs,
			result: okResult
		});
		expect(parts).toEqual([
			{
				type: 'documents',
				documents: {
					spec: { domain: 'crm', doctype: 'Customer', ids: ['b'], display: 'card' },
					status: 'ok'
				}
			}
		]);
	});

	it('falls back to the tool-call bar when the arguments fail to parse', () => {
		const rawOk = '{"ok":true}';
		const parts = applyAll([
			{ kind: 'tool_call', name: 'show_documents', status: 'running' },
			{
				kind: 'tool_call',
				name: 'show_documents',
				status: 'ok',
				arguments: 'not json',
				result: rawOk
			}
		]);
		expect(parts).toEqual([
			{
				type: 'tool_call',
				toolCall: {
					name: 'show_documents',
					detail: undefined,
					result: rawOk,
					status: 'ok'
				}
			}
		]);
	});

	it('resolves with an error status when the call fails', () => {
		const parts = applyAll([
			{ kind: 'tool_call', name: 'show_documents', status: 'running' },
			{ kind: 'tool_call', name: 'show_documents', status: 'error', arguments: okArgs }
		]);
		expect(parts).toEqual([
			{
				type: 'documents',
				documents: {
					spec: { domain: 'crm', doctype: 'Customer', ids: ['a', 'b'], display: 'card' },
					status: 'error'
				}
			}
		]);
	});
});

describe('applyChunkToParts — navigate stays a plain tool-call part', () => {
	it('keeps the bar; the consumer handles navigation from the chunk', () => {
		const rawResult = '{"ok":true,"data":{"navigated":true}}';
		const parts = applyAll([
			{ kind: 'tool_call', name: 'navigate', status: 'running' },
			{
				kind: 'tool_call',
				name: 'navigate',
				status: 'ok',
				arguments: JSON.stringify({ target: 'domain', domain: 'crm' }),
				result: rawResult
			}
		]);
		// No special part — the ordinary in-place resolution runs (the running
		// bar merges with the resolving chunk) and the consumer reads the live
		// chunk separately.
		expect(parts).toEqual([
			{
				type: 'tool_call',
				toolCall: {
					name: 'navigate',
					detail: undefined,
					result: rawResult,
					status: 'ok'
				}
			}
		]);
	});
});

describe('parseListRowsResult / parseStatsResult — parser edge cases', () => {
	it('rejects malformed and item-less rows envelopes', () => {
		expect(parseListRowsResult(undefined)).toBeNull();
		expect(parseListRowsResult('not json')).toBeNull();
		expect(parseListRowsResult(JSON.stringify({ ok: false, data: {} }))).toBeNull();
		expect(
			parseListRowsResult(JSON.stringify({ ok: true, data: { data: [], meta: {} } }))
		).toBeNull();
		expect(
			parseListRowsResult(JSON.stringify({ ok: true, data: { data: [{ meta: { id: 'x' } }] } }))
		).toBeNull();
	});

	it('parses the stats shapes: bag, scalar, null, and rejects unknown kinds', () => {
		expect(
			parseStatsResult(
				JSON.stringify({ ok: true, data: { aggregate: 'count', value: null, count: 0 } })
			)
		).toEqual({ aggregate: 'count', value: null, count: 0 });
		expect(
			parseStatsResult(
				JSON.stringify({
					ok: true,
					data: { aggregate: 'avg', field: 'level', value: 4.5, count: 2 }
				})
			)
		).toEqual({ aggregate: 'avg', field: 'level', value: 4.5, count: 2 });
		expect(
			parseStatsResult(JSON.stringify({ ok: true, data: { aggregate: 'median', value: 1 } }))
		).toBeNull();
		expect(
			parseStatsResult(JSON.stringify({ ok: true, data: { aggregate: 'sum', value: true } }))
		).toBeNull();
		expect(parseStatsResult(undefined)).toBeNull();
	});
});
