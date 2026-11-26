// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { marked, type Token, type Tokens } from 'marked';
import hljs from 'highlight.js/lib/common';
import { EMOJI_MAP } from './emoji-map';

// Disable inline HTML and walk the AST to render only allowlisted token
// types. Anything we don't recognise is rendered as plain (escaped) text.
// This is the "no fragile string parsing" approach: marked tokenises, we
// render. We never inject raw HTML from the source string.
marked.setOptions({
	gfm: true,
	breaks: true
});

// ── Inline HTML allowlist ─────────────────────────────────────────────
// Tags we accept raw from the source markdown. Attributes are stripped
// unconditionally; unknown tags render as escaped text. This keeps the
// surface area small while supporting <kbd>, <mark>, <sub>, <sup>, etc.
const ALLOWED_INLINE_TAGS = new Set([
	'kbd',
	'mark',
	'sub',
	'sup',
	'b',
	'i',
	'em',
	'strong',
	'code',
	'small',
	'u',
	's',
	'br',
	'wbr',
	'span'
]);

/**
 * Sanitize a single inline HTML tag fragment produced by marked's `tag`
 * tokenizer. Returns either a clean tag (no attributes) for allowlisted
 * tag names, or escaped text for anything else. Never injects attributes
 * or unknown tags.
 */
function sanitizeInlineHtml(raw: string): string {
	// Opening or self-closing tag: <tag> | <tag/> | <tag attrs...>
	const open = /^<([a-zA-Z][a-zA-Z0-9-]*)(?:\s+[^>]*?)?\s*\/?>$/.exec(raw);
	if (open) {
		const name = open[1].toLowerCase();
		if (ALLOWED_INLINE_TAGS.has(name)) {
			return name === 'br' || name === 'wbr' ? `<${name}>` : `<${name}>`;
		}
		return escapeHtml(raw);
	}
	// Closing tag: </tag>
	const close = /^<\/([a-zA-Z][a-zA-Z0-9-]*)\s*>$/.exec(raw);
	if (close) {
		const name = close[1].toLowerCase();
		if (ALLOWED_INLINE_TAGS.has(name)) {
			return `</${name}>`;
		}
		return escapeHtml(raw);
	}
	// Comments, declarations, CDATA, etc.: never render.
	return escapeHtml(raw);
}

// ── Custom marked extensions ──────────────────────────────────────────
// Tokenizers register new AST node types; we render them in our own
// `renderToken` switch below (we don't use marked's Parser).
//
// Inline tokenizers run BEFORE marked's `del` / `codespan`, so subscript
// (~) must require a non-`~` char right after the opening tilde (so
// `~~strikethrough~~` falls through to marked's `del` tokenizer).
marked.use({
	extensions: [
		// :emoji: → unicode
		{
			name: 'emoji',
			level: 'inline',
			start(src: string) {
				return src.indexOf(':');
			},
			tokenizer(src: string) {
				const m = /^:([a-z0-9_+-]+):/.exec(src);
				if (!m) return;
				const code = EMOJI_MAP[m[1]];
				if (!code) return;
				return { type: 'emoji', raw: m[0], text: code } satisfies Tokens.Generic;
			}
		},
		// ==highlight== → <mark>
		{
			name: 'mark',
			level: 'inline',
			start(src: string) {
				return src.indexOf('==');
			},
			tokenizer(src: string, _tokens: Token[]) {
				const m = /^==([^\s=](?:[^=]*[^\s=])?)==/.exec(src);
				if (!m) return;
				const inner = m[0].slice(2, -2);
				return {
					type: 'mark',
					raw: m[0],
					text: inner,
					tokens: this.lexer.inlineTokens(inner, [])
				} satisfies Tokens.Generic;
			},
			childTokens: ['tokens']
		},
		// ^superscript^ → <sup>
		{
			name: 'sup',
			level: 'inline',
			start(src: string) {
				return src.indexOf('^');
			},
			tokenizer(src: string, _tokens: Token[]) {
				const m = /^\^([^\s^](?:[^\n^]*[^\s^])?)\^(?=[^^]|$)/.exec(src);
				if (!m) return;
				const inner = m[0].slice(1, -1);
				return {
					type: 'sup',
					raw: m[0],
					text: inner,
					tokens: this.lexer.inlineTokens(inner, [])
				} satisfies Tokens.Generic;
			},
			childTokens: ['tokens']
		},
		// ~subscript~ → <sub> (single ~; ~~…~~ still goes to `del`)
		{
			name: 'sub',
			level: 'inline',
			start(src: string) {
				return src.indexOf('~');
			},
			tokenizer(src: string, _tokens: Token[]) {
				const m = /^~([^\s~](?:[^\n~]*[^\s~])?)~(?!~)/.exec(src);
				if (!m) return;
				const inner = m[0].slice(1, -1);
				return {
					type: 'sub',
					raw: m[0],
					text: inner,
					tokens: this.lexer.inlineTokens(inner, [])
				} satisfies Tokens.Generic;
			},
			childTokens: ['tokens']
		},
		// Definition list block:
		//   Term
		//   : Definition
		{
			name: 'deflist',
			level: 'block',
			start(src: string) {
				const m = /^[^\n:][^\n]*\n[ \t]*:[ \t]+/m.exec(src);
				return m ? m.index : undefined;
			},
			tokenizer(src: string, _tokens: Token[]) {
				const rule = /^(?:[^\n:][^\n]*\n(?:[ \t]*:[ \t]+[^\n]*(?:\n|$))+)+/;
				const m = rule.exec(src);
				if (!m) return;
				const block = m[0];
				const items: Array<{ kind: 'dt' | 'dd'; tokens: Token[] }> = [];
				for (const rawLine of block.split('\n')) {
					const def = /^[ \t]*:[ \t]+(.*)$/.exec(rawLine);
					if (def) {
						items.push({
							kind: 'dd',
							tokens: this.lexer.inlineTokens(def[1], [])
						});
					} else {
						// term line (may be empty at the trailing newline)
						if (rawLine.length === 0) continue;
						items.push({
							kind: 'dt',
							tokens: this.lexer.inlineTokens(rawLine, [])
						});
					}
				}
				return {
					type: 'deflist',
					raw: block,
					text: block,
					items
				} satisfies Tokens.Generic;
			},
			childTokens: ['items.tokens']
		}
	]
});

export type Segment =
	| { kind: 'html'; html: string }
	| { kind: 'code'; lang: string | null; code: string }
	| { kind: 'mermaid'; source: string };

function escapeHtml(s: string): string {
	return s
		.replace(/&/g, '&amp;')
		.replace(/</g, '&lt;')
		.replace(/>/g, '&gt;')
		.replace(/"/g, '&quot;')
		.replace(/'/g, '&#39;');
}

// ── URL scheme allowlist ──────────────────────────────────────────────
// Escaping entities does not stop a `javascript:` href or a remote image
// that the browser fetches on its own (a prompt-injected document can
// exfiltrate data through an image URL). Links and images therefore pass
// a scheme check before an `href` / `src` is emitted.

// Anchors: web links and mail. Relative and fragment URLs are kept as-is
// (they resolve against the app origin). Everything else — `javascript:`,
// `data:`, `vbscript:`, `file:`, unknown schemes — renders as text.
const ALLOWED_LINK_SCHEMES = new Set(['http:', 'https:', 'mailto:']);

// Images: only remote http(s) resources. `data:` images are rejected: a
// data URL is a free channel to the page itself and gives nothing a
// legitimate chat diagram needs.
const ALLOWED_IMAGE_SCHEMES = new Set(['http:', 'https:']);

/**
 * Resolve a markdown URL to a parsed `URL` when it carries a scheme.
 * Returns `null` for relative URLs and fragments (no scheme). The base
 * origin is irrelevant: we only read `protocol`.
 */
function parseScheme(url: string): string | null {
	const trimmed = url.trim();
	if (!trimmed || trimmed.startsWith('#') || trimmed.startsWith('//')) return null;
	try {
		return new URL(trimmed).protocol.toLowerCase();
	} catch {
		// Relative path — no scheme to inspect.
		return null;
	}
}

function isAllowedLinkUrl(url: string): boolean {
	const scheme = parseScheme(url);
	return scheme === null || ALLOWED_LINK_SCHEMES.has(scheme);
}

function isAllowedImageUrl(url: string): boolean {
	const scheme = parseScheme(url);
	return scheme !== null && ALLOWED_IMAGE_SCHEMES.has(scheme);
}

function renderInline(tokens: Token[] | undefined): string {
	if (!tokens) return '';
	return tokens.map(renderToken).join('');
}

function renderToken(tok: Token): string {
	switch (tok.type) {
		case 'emoji':
			return escapeHtml((tok as Tokens.Generic).text as string);
		case 'mark':
			return `<mark>${renderInline((tok as Tokens.Generic).tokens as Token[])}</mark>`;
		case 'sup':
			return `<sup>${renderInline((tok as Tokens.Generic).tokens as Token[])}</sup>`;
		case 'sub':
			return `<sub>${renderInline((tok as Tokens.Generic).tokens as Token[])}</sub>`;
		case 'deflist': {
			const items = (tok as Tokens.Generic).items as Array<{
				kind: 'dt' | 'dd';
				tokens: Token[];
			}>;
			const body = items
				.map((it) =>
					it.kind === 'dt'
						? `<dt>${renderInline(it.tokens)}</dt>`
						: `<dd>${renderInline(it.tokens)}</dd>`
				)
				.join('');
			return `<dl>${body}</dl>`;
		}
		case 'paragraph':
			return `<p>${renderInline(tok.tokens)}</p>`;
		case 'text':
			return tok.tokens ? renderInline(tok.tokens) : escapeHtml(tok.text);
		case 'strong':
			return `<strong>${renderInline(tok.tokens)}</strong>`;
		case 'em':
			return `<em>${renderInline(tok.tokens)}</em>`;
		case 'del':
			return `<del>${renderInline(tok.tokens)}</del>`;
		case 'codespan':
			return `<code>${escapeHtml(tok.text)}</code>`;
		case 'link': {
			// A disallowed scheme drops the anchor: render the link text as
			// plain inline content so the reader still sees the words.
			if (!isAllowedLinkUrl(tok.href)) return renderInline(tok.tokens);
			const href = escapeHtml(tok.href);
			const title = tok.title ? ` title="${escapeHtml(tok.title)}"` : '';
			return `<a href="${href}"${title} rel="noopener noreferrer" target="_blank">${renderInline(tok.tokens)}</a>`;
		}
		case 'image': {
			// A disallowed source emits no <img>: the browser must not fetch
			// it. Keep the alt text so the content stays readable.
			if (!isAllowedImageUrl(tok.href)) return escapeHtml(tok.text);
			const src = escapeHtml(tok.href);
			const alt = escapeHtml(tok.text);
			const title = tok.title ? ` title="${escapeHtml(tok.title)}"` : '';
			return `<img src="${src}" alt="${alt}"${title} loading="lazy" />`;
		}
		case 'list': {
			const lt = tok as Tokens.List;
			const tag = lt.ordered ? 'ol' : 'ul';
			const start = lt.ordered && lt.start !== 1 ? ` start="${lt.start}"` : '';
			const items = lt.items
				.map((it: Tokens.ListItem) => {
					const inner = renderInline(it.tokens);
					// Task list item: mark with data attribute, but do NOT render
					// a disabled checkbox element (the assistant can't interact).
					if (it.task) {
						return `<li class="md-task" data-checked="${it.checked ? 'true' : 'false'}">${inner}</li>`;
					}
					return `<li>${inner}</li>`;
				})
				.join('');
			return `<${tag}${start}>${items}</${tag}>`;
		}
		case 'list_item':
			return renderInline(tok.tokens);
		case 'blockquote':
			return `<blockquote>${renderInline(tok.tokens)}</blockquote>`;
		case 'heading': {
			const level = Math.min(Math.max(tok.depth, 1), 6);
			return `<h${level}>${renderInline(tok.tokens)}</h${level}>`;
		}
		case 'hr':
			return '<hr />';
		case 'br':
			return '<br />';
		case 'html':
		case 'tag':
			return sanitizeInlineHtml((tok as Tokens.HTML | Tokens.Tag).text);
		case 'escape':
			return escapeHtml(tok.text);
		case 'space':
			return '';
		case 'table': {
			const alignClass = (a: 'center' | 'left' | 'right' | null) =>
				a ? ` class="md-tbl-${a}"` : '';
			const head = tok.header
				.map(
					(cell: Tokens.TableCell) =>
						`<th${alignClass(cell.align)}>${renderInline(cell.tokens)}</th>`
				)
				.join('');
			const body = tok.rows
				.map(
					(row: Tokens.TableCell[]) =>
						'<tr>' +
						row
							.map(
								(cell: Tokens.TableCell) =>
									`<td${alignClass(cell.align)}>${renderInline(cell.tokens)}</td>`
							)
							.join('') +
						'</tr>'
				)
				.join('');
			return `<div class="md-tbl-wrap"><table><thead><tr>${head}</tr></thead><tbody>${body}</tbody></table></div>`;
		}
		default: {
			// Any unrecognised token (raw HTML, tag, def, generic): render
			// its raw text escaped, never the raw HTML.
			const raw = (tok as { text?: unknown }).text;
			return typeof raw === 'string' ? escapeHtml(raw) : '';
		}
	}
}

// Highlight a code block with highlight.js. Falls back to auto-detection
// when the language is unknown or unregistered, and to plain escaped text
// if auto-detection finds nothing. Returns highlighted HTML with hljs
// class names (styled in the Markdown component's <style>).
export function highlightCode(code: string, lang: string | null): string {
	if (lang && hljs.getLanguage(lang)) {
		try {
			return hljs.highlight(code, { language: lang }).value;
		} catch {
			// fall through to auto
		}
	}
	try {
		return hljs.highlightAuto(code).value;
	} catch {
		return escapeHtml(code);
	}
}

// Walk the top-level token stream. Fenced code blocks become their own
// segment so the component can render them with highlight.js. Mermaid
// blocks become a mermaid segment. Everything else is concatenated into
// an html segment.
export function renderMarkdown(md: string): Segment[] {
	if (!md) return [];
	const tokens = marked.lexer(md);
	const segments: Segment[] = [];
	let htmlBuf = '';

	const flush = () => {
		if (htmlBuf) {
			segments.push({ kind: 'html', html: htmlBuf });
			htmlBuf = '';
		}
	};

	for (const tok of tokens) {
		if (tok.type === 'code') {
			flush();
			if (tok.lang === 'mermaid') {
				segments.push({ kind: 'mermaid', source: tok.text });
			} else {
				segments.push({ kind: 'code', lang: tok.lang || null, code: tok.text });
			}
		} else {
			htmlBuf += renderToken(tok);
		}
	}
	flush();
	return segments;
}
