// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it } from 'vitest';
import { isSameMarkdownDocument, normalizeMarkdown } from './markdown-normalize.js';

describe('normalizeMarkdown — Milkdown empty-paragraph convention', () => {
	it('collapses a br-only line between paragraphs to a paragraph break', () => {
		expect(normalizeMarkdown('First line.\n\n<br />\n\nSecond line.\n')).toBe(
			'First line.\n\nSecond line.\n'
		);
	});

	it('accepts every br variant the parser recognizes', () => {
		for (const br of ['<br>', '<br/>', '<br />', '<br >', '<BR />']) {
			expect(normalizeMarkdown(`A\n\n${br}\n\nB\n`)).toBe('A\n\nB\n');
		}
	});

	it('collapses consecutive br-only lines to one break', () => {
		expect(normalizeMarkdown('A\n\n<br />\n\n<br />\n\nB\n')).toBe('A\n\nB\n');
	});

	it('drops a leading br-only line', () => {
		expect(normalizeMarkdown('<br />\n\nB\n')).toBe('B\n');
	});

	it('keeps a br-only line inside a fenced code block', () => {
		const source = 'Before.\n\n```\n<br />\n```\n\nAfter.\n';
		expect(normalizeMarkdown(source)).toBe(source);
	});

	it('keeps blank-line runs inside a fenced code block', () => {
		const source = '```ts\nconst a = 1;\n\n\nconst b = 2;\n```\n';
		expect(normalizeMarkdown(source)).toBe(source);
	});

	it('drops a blockquote-prefixed br line without splitting the quote', () => {
		expect(normalizeMarkdown('> quoted.\n> <br />\n> more.\n')).toBe('> quoted.\n> more.\n');
	});

	it('leaves plain markdown untouched', () => {
		const source = '# Title\n\nIntro with a soft\nbreak.\n\n- one\n- two\n';
		expect(normalizeMarkdown(source)).toBe(source);
	});

	it('leaves inline html br untouched (only br-only lines are structural)', () => {
		const source = 'A <br /> B\n';
		expect(normalizeMarkdown(source)).toBe(source);
	});

	it('collapses pre-existing blank runs between paragraphs', () => {
		expect(normalizeMarkdown('A\n\n\n\nB\n')).toBe('A\n\nB\n');
	});

	it('is idempotent', () => {
		const once = normalizeMarkdown('A\n\n<br />\n\n<br />\n\n```js\n\n\nx\n```\n\nB\n');
		expect(normalizeMarkdown(once)).toBe(once);
	});

	it('returns an empty string for empty input', () => {
		expect(normalizeMarkdown('')).toBe('');
		expect(normalizeMarkdown('\n')).toBe('');
	});
});

describe('isSameMarkdownDocument — re-serialization vs a real edit', () => {
	it('counts the bullet-marker rewrite as unchanged (`- a` vs `* a\n`)', () => {
		// The filed F10-G case: prosemirror-markdown's default bullet is `*`,
		// so any edit re-serializes a stored `- a` bullet as `* a\n`.
		expect(isSameMarkdownDocument('- a', '* a\n')).toBe(true);
		expect(isSameMarkdownDocument('- a', '* a')).toBe(true);
		expect(isSameMarkdownDocument('- a\n- b', '* a\n* b\n')).toBe(true);
	});

	it('counts a genuinely different text as changed', () => {
		expect(isSameMarkdownDocument('- a', '- b\n')).toBe(false);
		expect(
			isSameMarkdownDocument('First line.\n\nSecond line.\n', 'First line.\n\nChanged line.\n')
		).toBe(false);
		expect(isSameMarkdownDocument('- a\n- b\n', '- a\n- b\n- c\n')).toBe(false);
		expect(isSameMarkdownDocument('# Title\n\nIntro\n', '## Title\n\nIntro\n')).toBe(false);
		expect(isSameMarkdownDocument('a *em* b\n', 'a **strong** b\n')).toBe(false);
		expect(isSameMarkdownDocument('text\n', '')).toBe(false);
		expect(isSameMarkdownDocument('', 'text\n')).toBe(false);
	});

	it('counts a trailing-newline-only difference as unchanged', () => {
		expect(isSameMarkdownDocument('- a', '- a\n')).toBe(true);
		expect(isSameMarkdownDocument('Text.', 'Text.\n')).toBe(true);
		expect(isSameMarkdownDocument('Text.\n\n', 'Text.\n')).toBe(true);
	});

	it('counts the other serializer restyles as unchanged', () => {
		// Emphasis marker choice (`_em_` → `*em*`), ordered-list delimiter
		// (`1)` → `1.`), setext → ATX heading, thematic-break marker, escape
		// spelling, and the `<br />` empty-paragraph convention.
		expect(isSameMarkdownDocument('_em_ text\n', '*em* text\n')).toBe(true);
		expect(isSameMarkdownDocument('1) one\n2) two\n', '1. one\n2. two\n')).toBe(true);
		expect(isSameMarkdownDocument('Title\n=====\n', '# Title\n')).toBe(true);
		expect(isSameMarkdownDocument('---\n', '***\n')).toBe(true);
		// Intraword underscores re-escape on serialize (`snake_case` →
		// `snake\_case`) — the parse is one text run either way.
		expect(isSameMarkdownDocument('snake_case_word\n', 'snake\\_case\\_word\n')).toBe(true);
		expect(isSameMarkdownDocument('A\n\nB\n', 'A\n\n<br />\n\nB\n')).toBe(true);
		expect(isSameMarkdownDocument('A\n\n\n\nB\n', 'A\n\nB\n')).toBe(true);
	});

	it('keeps inline structure distinct from its plain-text look', () => {
		expect(isSameMarkdownDocument('a _b_ c\n', 'a b c\n')).toBe(false);
		// Escaped (literal) markers vs real emphasis are different documents.
		expect(isSameMarkdownDocument('a \\_b\\_ c\n', 'a _b_ c\n')).toBe(false);
		expect(isSameMarkdownDocument('[label](https://x)\n', 'label\n')).toBe(false);
		expect(isSameMarkdownDocument('`code` tail\n', 'code tail\n')).toBe(false);
		expect(isSameMarkdownDocument('- a\n\n- b\n', '- a\n- b\n- c\n')).toBe(false);
	});
});
