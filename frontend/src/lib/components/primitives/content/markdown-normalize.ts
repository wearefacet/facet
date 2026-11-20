// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Normalize editor-produced markdown before it leaves `Milkdown.svelte`.
 *
 * Milkdown serializes an **empty paragraph** (a blank line made with Enter
 * in the WYSIWYG, or pasted empty `<p>` elements) as a literal `<br />`
 * line — the upstream "preserve empty line" convention, because plain
 * markdown cannot express an empty paragraph. The convention must not
 * reach storage: longtext values are markdown read by API consumers,
 * search indexing, and plain-text renderers, and none of them should ever
 * see HTML in the source.
 *
 * `normalizeMarkdown` rewrites the convention back to plain markdown:
 *
 * - A line holding only a `<br>` variant (`<br>`, `<br/>`, `<br />`,
 *   `<br >`, case-insensitive) is dropped. Around it, runs of blank lines
 *   collapse to a single paragraph break — the standard markdown meaning
 *   of the blank line the user typed.
 * - Fenced code blocks pass through verbatim: blank-line runs and
 *   `<br>`-looking lines inside a fence are content, not structure.
 * - A blockquote-prefixed br-only line (`> <br />`) is dropped without
 *   introducing a blank line, so the quote does not split into two.
 *
 * The result is idempotent and always ends with one trailing newline.
 *
 * The module also answers one comparison question for the editor: does a
 * fresh serialization carry a real edit, or only the serializer's own
 * re-serialization of the same parsed document? `isSameMarkdownDocument`
 * parses both texts with the `marked` lexer and compares the token trees,
 * so marker-level rewrites (`- a` → `* a\n`, `_em_` → `*em*`) read as the
 * same document while any content change reads as different. It is pure and
 * runs in the Vitest `server` project.
 */

import { lexer } from 'marked';

/** A line whose only content is a br tag — Milkdown's empty-paragraph serialization. */
const BR_ONLY = /^<br\s*\/?>$/i;

/** An opening or closing fence marker (` ``` `, `~~~`, optionally with an info string). */
const FENCE = /^(?:`{3,}|~{3,})/;

/** Leading blockquote markers on a line. */
const QUOTE = /^>+\s?/;

export function normalizeMarkdown(source: string): string {
	const lines = source.split('\n');
	const out: string[] = [];
	// Blank lines (and dropped br-only lines) pending before the next content
	// line — flushed as at most one blank line, markdown's paragraph break.
	let pendingBlanks = 0;
	// Opening fence character while inside a fenced code block, else null.
	let fence: string | null = null;

	const flushBlanks = () => {
		const blanks = Math.min(pendingBlanks, 1);
		for (let i = 0; i < blanks; i++) out.push('');
		pendingBlanks = 0;
	};

	for (const line of lines) {
		const trimmed = line.trim();

		if (fence !== null) {
			// Fence content is verbatim — never rewritten.
			out.push(line);
			if (FENCE.test(trimmed) && trimmed[0] === fence) fence = null;
			continue;
		}

		const openingFence = FENCE.exec(trimmed);
		if (openingFence) {
			flushBlanks();
			out.push(line);
			fence = openingFence[0][0];
			continue;
		}

		// A br-only line is Milkdown's stand-in for an empty paragraph, i.e.
		// another blank line. A blockquote-prefixed one is dropped outright so
		// the surrounding quote keeps its lines contiguous.
		const quoted = QUOTE.exec(trimmed);
		const bare = quoted ? trimmed.slice(quoted[0].length) : trimmed;
		if (BR_ONLY.test(bare)) {
			if (!quoted) pendingBlanks++;
			continue;
		}

		if (trimmed === '') {
			pendingBlanks++;
			continue;
		}

		flushBlanks();
		out.push(line);
	}

	// Trim trailing blanks, strip leading blanks (markdown cannot express
	// either), and end with exactly one trailing newline.
	while (out.length > 0 && out[out.length - 1] === '') out.pop();
	return `${out.join('\n')}\n`.replace(/^\n+/, '');
}

// ── Same-document comparison ────────────────────────────────────────────
//
// Milkdown's serializer is not a fixed point of parse∘serialize: any
// doc-changing transaction re-serializes the whole field, and the output can
// differ from the stored source at marker level (`- a` → `* a\n`,
// `_em_` → `*em*`, `1)` → `1.`, setext → ATX). The editor must emit a change
// only when the parsed document changed, never on a pure re-serialization.
//
// Both texts go through one parser (the `marked` lexer), so every rewrite
// that preserves the parse reads as the same document. The projection below
// keeps the fields that carry document meaning and drops the bookkeeping the
// serializer is free to restyle: source positions, list/quote/emphasis
// marker characters, tight-vs-loose spacing, escape spellings.

/** Structural view of a `marked` token — only the fields the projection reads. */
interface MarkedToken {
	type: string;
	text?: string;
	lang?: string;
	depth?: number;
	ordered?: boolean;
	start?: number | string;
	task?: boolean;
	checked?: boolean;
	href?: string;
	title?: string | null;
	align?: (string | null)[];
	tokens?: MarkedToken[] | null;
	items?: MarkedToken[];
	header?: MarkedToken[];
	rows?: MarkedToken[][];
}

/** Inline tokens project through their children; `escape` folds into plain text. */
function projectInline(token: MarkedToken): unknown {
	switch (token.type) {
		case 'escape':
			return { t: 'text', text: token.text ?? '' };
		case 'text':
			return { t: 'text', text: token.text ?? '' };
		case 'codespan':
			return { t: 'codespan', text: token.text ?? '' };
		case 'strong':
			return { t: 'strong', c: projectInlineAll(token.tokens ?? []) };
		case 'em':
			return { t: 'em', c: projectInlineAll(token.tokens ?? []) };
		case 'del':
			return { t: 'del', c: projectInlineAll(token.tokens ?? []) };
		case 'br':
			return { t: 'br' };
		case 'link':
			return {
				t: 'link',
				href: token.href ?? '',
				title: token.title ?? '',
				c: projectInlineAll(token.tokens ?? [])
			};
		case 'image':
			return {
				t: 'image',
				href: token.href ?? '',
				title: token.title ?? '',
				text: token.text ?? ''
			};
		case 'html':
			return { t: 'html', text: token.text ?? '' };
		default:
			// Unknown inline token: compare by type only — fail toward "changed".
			return { t: token.type };
	}
}

/** A projection of one inline token — the shapes `projectInline` builds. */
interface TextProjection {
	t: string;
	text?: string;
}

const isText = (p: unknown): p is TextProjection =>
	typeof p === 'object' && p !== null && (p as TextProjection).t === 'text';

/** Project an inline token list, folding adjacent text projections. Escape
 *  spellings split one run of plain text into several tokens (`snake_case`
 *  → `snake\_case`); the run is one text node in the parsed document. */
function projectInlineAll(tokens: MarkedToken[]): unknown[] {
	const out: unknown[] = [];
	for (const token of tokens) {
		const projected = projectInline(token);
		const last = out.length > 0 ? out[out.length - 1] : null;
		if (isText(projected) && isText(last)) {
			out[out.length - 1] = { t: 'text', text: `${last.text ?? ''}${projected.text ?? ''}` };
			continue;
		}
		out.push(projected);
	}
	return out;
}

/** Block tokens project recursively; blank `space` tokens and link
 *  definitions drop — the serializer restyles both freely. */
function projectBlock(token: MarkedToken): unknown {
	switch (token.type) {
		case 'space':
			return null;
		case 'def':
			return null;
		case 'code':
			return { t: 'code', lang: token.lang ?? '', text: token.text ?? '' };
		case 'heading':
			return { t: 'heading', depth: token.depth ?? 0, c: projectInlineAll(token.tokens ?? []) };
		case 'hr':
			return { t: 'hr' };
		case 'blockquote':
			return {
				t: 'blockquote',
				c: (token.tokens ?? []).map(projectBlock).filter((x) => x !== null)
			};
		case 'list':
			return {
				t: 'list',
				ordered: token.ordered === true,
				start: token.ordered === true ? Number(token.start || 1) : 0,
				items: (token.items ?? []).map(projectBlock).filter((x) => x !== null)
			};
		case 'list_item':
			return {
				t: 'item',
				task: token.task === true,
				checked: token.task === true ? token.checked === true : null,
				c: (token.tokens ?? []).map(projectBlock).filter((x) => x !== null)
			};
		case 'table':
			return {
				t: 'table',
				align: (token.align ?? []).map((a) => a ?? null),
				head: (token.header ?? []).map((cell) => projectInlineAll(cell.tokens ?? [])),
				rows: (token.rows ?? []).map((row) =>
					row.map((cell) => projectInlineAll(cell.tokens ?? []))
				)
			};
		case 'html':
			return { t: 'html', text: token.text ?? '' };
		case 'paragraph':
			return { t: 'para', c: projectInlineAll(token.tokens ?? []) };
		case 'text':
			// A loose list item or quote line — same document meaning as a paragraph.
			return { t: 'para', c: projectInlineAll(token.tokens ?? []) };
		default:
			// Unknown block token: compare by type only — fail toward "changed".
			return { t: token.type };
	}
}

/** A comparable fingerprint of the parsed document. Key order in the built
 *  objects is fixed, so plain string equality works. */
function documentFingerprint(source: string): string {
	const tokens = lexer(source) as unknown as MarkedToken[];
	return JSON.stringify(tokens.map(projectBlock).filter((x) => x !== null));
}

/**
 * True when `candidate` is the same markdown document as `committed` —
 * equal as text, or equal after the parser strips the serializer's marker
 * and spacing choices. Pure re-serialization compares equal; any change to
 * content, structure, or inline formatting compares different.
 */
export function isSameMarkdownDocument(committed: string, candidate: string): boolean {
	const a = normalizeMarkdown(committed);
	const b = normalizeMarkdown(candidate);
	if (a === b) return true;
	return documentFingerprint(a) === documentFingerprint(b);
}
