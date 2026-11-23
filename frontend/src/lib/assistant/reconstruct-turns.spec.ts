// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { reconstructTurns } from './reconstruct-turns.js';
import type { AgentMessage } from './types.js';

describe('reconstructTurns — real persisted backend data', () => {
	const raw = readFileSync(
		fileURLToPath(new URL('./fixtures/real-turn-3.json', import.meta.url)),
		'utf8'
	);
	const response = JSON.parse(raw) as AgentMessage[];
	const request: AgentMessage[] = [
		{
			role: 'user',
			content: '[Page context: Viewing: _06fwqaxxkw1q · overview]\n\nCan you continue'
		}
	];

	it('produces the user turn plus every agent segment', () => {
		const out = reconstructTurns(request, response);
		expect(out[0]).toEqual({ kind: 'user', content: request[0].content });
		// 28 assistant messages in the fixture → 28 agent segments.
		const agentSegments = out.filter((t) => t.kind === 'agent');
		expect(agentSegments.length).toBe(28);
		// The last segment is the final 3820-char text answer.
		const last = agentSegments[agentSegments.length - 1];
		if (last.kind !== 'agent') throw new Error('expected agent');
		expect(last.parts).toEqual([{ type: 'text', content: expect.stringContaining('party') }]);
	});

	it('renders tool-call steps with results resolved', () => {
		const out = reconstructTurns(request, response);
		const segments = out.filter((t) => t.kind === 'agent');
		// Segment 0 carries the first read_skill + list_domains tool calls.
		const first = segments[0];
		if (first.kind !== 'agent') throw new Error('expected agent');
		const toolCalls = first.parts.filter((p) => p.type === 'tool_call');
		expect(toolCalls.length).toBe(4);
		// Every tool call has its result attached (all ids resolve in fixture).
		for (const p of toolCalls) {
			if (p.type !== 'tool_call') continue;
			expect(p.toolCall.result).toBeTruthy();
			expect(p.toolCall.status).toBe('ok');
		}
	});

	it('keeps empty-content assistant messages that carry tool_calls', () => {
		const out = reconstructTurns(request, response);
		const segments = out.filter((t) => t.kind === 'agent');
		// A number of assistant messages have empty content but tool_calls — they
		// must still appear as agent segments (the step bar), not be dropped.
		const toolOnly = segments.filter((t) => {
			if (t.kind !== 'agent') return false;
			return t.parts.length > 0 && t.parts.every((p) => p.type === 'tool_call');
		});
		expect(toolOnly.length).toBeGreaterThan(0);
	});
});

describe('reconstructTurns — reasoning', () => {
	it('emits a leading reasoning part when the assistant message carries reasoning', () => {
		const request: AgentMessage[] = [{ role: 'user', content: 'hi' }];
		const response: AgentMessage[] = [
			{ role: 'assistant', content: 'Done.', reasoning: 'I thought about this.' }
		];
		const out = reconstructTurns(request, response);
		const last = out[out.length - 1];
		expect(last.kind).toBe('agent');
		if (last.kind !== 'agent') throw new Error('expected agent');
		expect(last.parts).toEqual([
			{ type: 'reasoning', content: 'I thought about this.' },
			{ type: 'text', content: 'Done.' }
		]);
	});

	it('omits the reasoning part when reasoning is absent', () => {
		const request: AgentMessage[] = [{ role: 'user', content: 'hi' }];
		const response: AgentMessage[] = [{ role: 'assistant', content: 'Done.' }];
		const out = reconstructTurns(request, response);
		const last = out[out.length - 1];
		expect(last.kind).toBe('agent');
		if (last.kind !== 'agent') throw new Error('expected agent');
		expect(last.parts).toEqual([{ type: 'text', content: 'Done.' }]);
	});
});

describe('reconstructTurns — cancelled turn', () => {
	const request: AgentMessage[] = [{ role: 'user', content: 'create the invoice doctype' }];
	const partial: AgentMessage[] = [
		{
			role: 'assistant',
			content: 'Let me create that.',
			tool_calls: [{ id: 'tc1', name: 'create_doctype', arguments: '{}' }]
		},
		{ role: 'tool', tool_call_id: 'tc1', name: 'create_doctype', content: 'created invoice' }
	];

	it('renders partial content plus a Cancelled marker when flagged', () => {
		const out = reconstructTurns(request, partial, true);
		const last = out[out.length - 1];
		expect(last.kind).toBe('agent');
		if (last.kind !== 'agent') throw new Error('expected agent');
		// Partial context is preserved (text + tool result).
		expect(
			last.parts.some((p) => p.type === 'text' && p.content.includes('Let me create that.'))
		).toBe(true);
		expect(last.parts.some((p) => p.type === 'tool_call')).toBe(true);
		// The Cancelled marker is appended to the final agent segment.
		expect(last.parts[last.parts.length - 1]).toEqual({
			type: 'text',
			content: expect.stringContaining('> Cancelled.')
		});
	});

	it('does not append a marker when not flagged', () => {
		const out = reconstructTurns(request, partial, false);
		const last = out[out.length - 1];
		expect(last.kind).toBe('agent');
		if (last.kind !== 'agent') throw new Error('expected agent');
		expect(last.parts.some((p) => p.type === 'text' && p.content.includes('> Cancelled.'))).toBe(
			false
		);
	});
});

describe('reconstructTurns — workspace tool replay', () => {
	const listEnvelope = JSON.stringify({
		ok: true,
		data: {
			data: [
				{
					data: { name: 'Aurora' },
					meta: { id: 'crm.Customer.1', domain: 'crm', doc_type: 'Customer' }
				}
			],
			meta: { total: 1, page: 1, truncated: false }
		}
	});
	const statsEnvelope = JSON.stringify({
		ok: true,
		data: { aggregate: 'sum', field: 'revenue', value: { USD: '10.00' }, count: 1 }
	});

	it('rebuilds rows and stats parts from the persisted tool results', () => {
		const response: AgentMessage[] = [
			{
				role: 'assistant',
				content: 'Pulling the numbers.',
				tool_calls: [
					{ id: 'tc1', name: 'list_documents', arguments: '{}' },
					{ id: 'tc2', name: 'aggregate_documents', arguments: '{}' }
				]
			},
			{ role: 'tool', tool_call_id: 'tc1', name: 'list_documents', content: listEnvelope },
			{ role: 'tool', tool_call_id: 'tc2', name: 'aggregate_documents', content: statsEnvelope }
		];
		const out = reconstructTurns([{ role: 'user', content: 'how many?' }], response);
		const seg = out[1];
		if (seg.kind !== 'agent') throw new Error('expected agent');
		expect(seg.parts).toEqual([
			{ type: 'text', content: 'Pulling the numbers.' },
			{
				type: 'rows',
				rows: {
					rows: [{ domain: 'crm', doctype: 'Customer', id: 'crm.Customer.1' }],
					total: 1
				}
			},
			{
				type: 'stats',
				stats: { aggregate: 'sum', field: 'revenue', value: { USD: '10.00' }, count: 1 }
			}
		]);
	});

	it('rebuilds the documents part from the persisted show_documents arguments', () => {
		const response: AgentMessage[] = [
			{
				role: 'assistant',
				content: 'Here they are.',
				tool_calls: [
					{
						id: 'tc1',
						name: 'show_documents',
						arguments: JSON.stringify({
							domain: 'crm',
							doctype: 'Customer',
							ids: ['a', 'b'],
							display: 'inline'
						})
					}
				]
			},
			{
				role: 'tool',
				tool_call_id: 'tc1',
				name: 'show_documents',
				content: JSON.stringify({ ok: true, data: { rendered: ['a'], skipped: ['b'] } })
			}
		];
		const out = reconstructTurns([{ role: 'user', content: 'show' }], response);
		const seg = out[1];
		if (seg.kind !== 'agent') throw new Error('expected agent');
		expect(seg.parts).toEqual([
			{ type: 'text', content: 'Here they are.' },
			{
				type: 'documents',
				documents: {
					spec: { domain: 'crm', doctype: 'Customer', ids: ['a'], display: 'inline' },
					status: 'ok'
				}
			}
		]);
	});

	it('falls back to the tool-call bar when a workspace payload breaks the contract', () => {
		const response: AgentMessage[] = [
			{
				role: 'assistant',
				content: '',
				tool_calls: [{ id: 'tc1', name: 'show_documents', arguments: 'broken' }]
			},
			{
				role: 'tool',
				tool_call_id: 'tc1',
				name: 'show_documents',
				content: 'Error executing tool: bad ids'
			}
		];
		const out = reconstructTurns([{ role: 'user', content: 'show' }], response);
		const seg = out[1];
		if (seg.kind !== 'agent') throw new Error('expected agent');
		expect(seg.parts).toEqual([
			{
				type: 'tool_call',
				toolCall: {
					name: 'show_documents',
					detail: undefined,
					result: 'Error executing tool: bad ids',
					status: 'error'
				}
			}
		]);
	});

	it('replays a navigate call as a plain tool-call bar — never re-navigates', () => {
		const response: AgentMessage[] = [
			{
				role: 'assistant',
				content: 'Opened for you.',
				tool_calls: [
					{
						id: 'tc1',
						name: 'navigate',
						arguments: JSON.stringify({ target: 'domain', domain: 'crm' })
					}
				]
			},
			{
				role: 'tool',
				tool_call_id: 'tc1',
				name: 'navigate',
				content: JSON.stringify({ ok: true, data: { navigated: true } })
			}
		];
		const out = reconstructTurns([{ role: 'user', content: 'open crm' }], response);
		const seg = out[1];
		if (seg.kind !== 'agent') throw new Error('expected agent');
		expect(seg.parts).toEqual([
			{ type: 'text', content: 'Opened for you.' },
			{
				type: 'tool_call',
				toolCall: {
					name: 'navigate',
					detail: 'target=domain, domain=crm',
					result: JSON.stringify({ ok: true, data: { navigated: true } }),
					status: 'ok'
				}
			}
		]);
	});
});

describe('reconstructTurns — preview_view replay', () => {
	const request: AgentMessage[] = [{ role: 'user', content: 'show me the view' }];
	const template = { type: 'label', value: '$name' };

	const response: AgentMessage[] = [
		{
			role: 'assistant',
			content: 'Here is the preview.',
			tool_calls: [
				{
					id: 'tc1',
					name: 'preview_view',
					arguments: JSON.stringify({ kind: 'document', template })
				}
			]
		},
		{ role: 'tool', tool_call_id: 'tc1', name: 'preview_view', content: '{"ok":true}' }
	];

	it('rebuilds the preview card from persisted arguments', () => {
		const out = reconstructTurns(request, response);
		const seg = out[1];
		expect(seg.kind).toBe('agent');
		if (seg.kind !== 'agent') throw new Error('expected agent');
		expect(seg.parts).toEqual([
			{ type: 'text', content: 'Here is the preview.' },
			{ type: 'preview', preview: { spec: { kind: 'document', template }, status: 'ok' } }
		]);
	});

	it('marks the preview as error when the tool result failed', () => {
		const out = reconstructTurns(request, [
			response[0],
			{
				role: 'tool',
				tool_call_id: 'tc1',
				name: 'preview_view',
				content: 'Error executing tool: bad payload'
			}
		]);
		const seg = out[1];
		if (seg.kind !== 'agent') throw new Error('expected agent');
		expect(seg.parts).toEqual([
			{ type: 'text', content: 'Here is the preview.' },
			{ type: 'preview', preview: { spec: { kind: 'document', template }, status: 'error' } }
		]);
	});

	it('marks the preview as error when the result envelope is ok:false', () => {
		const out = reconstructTurns(request, [
			response[0],
			{
				role: 'tool',
				tool_call_id: 'tc1',
				name: 'preview_view',
				content: JSON.stringify({ ok: false, error: "Missing 'template' argument" })
			}
		]);
		const seg = out[1];
		if (seg.kind !== 'agent') throw new Error('expected agent');
		expect(seg.parts).toEqual([
			{ type: 'text', content: 'Here is the preview.' },
			{ type: 'preview', preview: { spec: { kind: 'document', template }, status: 'error' } }
		]);
	});
});
