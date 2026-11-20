// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it } from 'vitest';
import { collapseContentChunks, workspaceScript, type AssistantScript } from './scripts.js';

function scriptWith(chunks: AssistantScript['chunks']): AssistantScript {
	return {
		match: (content) => content === 'test',
		chunks,
		outcome: { kind: 'done', finish_reason: 'stop' },
		usage: { prompt_tokens: 1, completion_tokens: 2, total_tokens: 3 }
	};
}

describe('collapseContentChunks', () => {
	it('merges runs of consecutive content chunks into one', () => {
		const collapsed = collapseContentChunks(
			scriptWith([
				{ kind: 'content', text: 'Hello ', delayMs: 35 },
				{ kind: 'content', text: 'there. ', delayMs: 35 },
				{ kind: 'content', text: 'Done.', delayMs: 35 }
			])
		);
		expect(collapsed.chunks).toEqual([{ kind: 'content', text: 'Hello there. Done.' }]);
	});

	it('keeps tool_call chunks in place between merged content runs', () => {
		const tool = {
			kind: 'tool_call',
			name: 'list_documents',
			status: 'running',
			delayMs: 30
		} as const;
		const collapsed = collapseContentChunks(
			scriptWith([
				{ kind: 'content', text: 'One ' },
				{ kind: 'content', text: 'two ' },
				tool,
				{ kind: 'content', text: 'Three ' },
				{ kind: 'content', text: 'four' }
			])
		);
		expect(collapsed.chunks).toEqual([
			{ kind: 'content', text: 'One two ' },
			tool,
			{ kind: 'content', text: 'Three four' }
		]);
	});

	it('leaves reasoning chunks untouched', () => {
		const reasoning = { kind: 'reasoning', text: 'thinking ', delayMs: 35 } as const;
		const collapsed = collapseContentChunks(
			scriptWith([reasoning, { kind: 'content', text: 'a ' }, { kind: 'content', text: 'b' }])
		);
		expect(collapsed.chunks).toEqual([reasoning, { kind: 'content', text: 'a b' }]);
	});

	it('passes through a script with no content chunks', () => {
		const tool = { kind: 'tool_call', name: 'inspect_domain', status: 'ok' } as const;
		const source = scriptWith([tool]);
		const collapsed = collapseContentChunks(source);
		expect(collapsed.chunks).toEqual([tool]);
	});

	it('keeps match, outcome, and usage from the source script', () => {
		const source = scriptWith([{ kind: 'content', text: 'x' }]);
		const collapsed = collapseContentChunks(source);
		expect(collapsed.match).toBe(source.match);
		expect(collapsed.outcome).toBe(source.outcome);
		expect(collapsed.usage).toBe(source.usage);
	});

	it('collapses the workspace script without losing its text or tools', () => {
		const collapsed = collapseContentChunks(workspaceScript);
		expect(collapsed.chunks.length).toBeLessThan(workspaceScript.chunks.length);
		const text = collapsed.chunks
			.filter((c) => c.kind === 'content')
			.map((c) => c.text)
			.join('');
		const sourceText = workspaceScript.chunks
			.filter((c) => c.kind === 'content')
			.map((c) => c.text)
			.join('');
		expect(text).toBe(sourceText);
		expect(text).toContain('anything else?');
		expect(collapsed.chunks.filter((c) => c.kind === 'tool_call').length).toBe(
			workspaceScript.chunks.filter((c) => c.kind === 'tool_call').length
		);
	});
});
