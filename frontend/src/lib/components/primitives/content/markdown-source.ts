// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Shared setup for raw markdown source editors (CodeMirror). Used by
 * `Display/Markdown.svelte` ("Markdown" mode) and `DvtInputLongtext.svelte`
 * (longtext source toggle) so both render the same syntax highlighting and
 * token-mapped editor theme.
 */
import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
import { languages } from '@codemirror/language-data';
import type { ThemeSpec } from 'svelte-codemirror-editor';
import { HighlightStyle, syntaxHighlighting } from '@codemirror/language';
import { tags as t } from '@lezer/highlight';

export const MD_LANG = markdown({ base: markdownLanguage, codeLanguages: languages });

export const syntaxHighlight = HighlightStyle.define([
	{ tag: t.heading1, fontSize: '1.4em', fontWeight: '600', fontFamily: 'var(--font-display)' },
	{ tag: t.heading2, fontSize: '1.25em', fontWeight: '600', fontFamily: 'var(--font-display)' },
	{ tag: t.heading3, fontSize: '1.1em', fontWeight: '600', fontFamily: 'var(--font-display)' },
	{ tag: [t.heading4, t.heading5, t.heading6], fontWeight: '600' },
	{ tag: t.emphasis, fontStyle: 'italic' },
	{ tag: t.strong, fontWeight: '700' },
	{ tag: t.link, color: 'var(--accent-ink)', textDecoration: 'underline' },
	{ tag: t.monospace, fontFamily: 'var(--font-mono)', color: 'var(--text-2)' },
	{ tag: t.quote, color: 'var(--text-2)', fontStyle: 'italic' }
]);

export const sourceEditorTheme: ThemeSpec = {
	'&': {
		height: '100%',
		fontSize: '13px',
		backgroundColor: 'transparent'
	},
	'.cm-scroller': {
		fontFamily: 'var(--font-mono)',
		lineHeight: '1.6'
	},
	'.cm-content': { padding: '12px 14px' },
	'.cm-line': { padding: '0' },
	'&.cm-focused': { outline: 'none' },
	'.cm-selectionBackground': { backgroundColor: 'var(--accent-weak)' },
	'&.cm-focused .cm-selectionBackground': { backgroundColor: 'var(--accent-weak)' },
	'.cm-cursor': { borderLeftColor: 'var(--text)' },
	'&.cm-focused .cm-cursor': { borderLeftColor: 'var(--accent)' },
	'.cm-gutters': { display: 'none' },
	'.cm-placeholder': { color: 'var(--text-3)' }
};

/** Ready-to-spread extension list for a `CodeMirror` markdown editor. */
export const sourceEditorExtensions = [syntaxHighlighting(syntaxHighlight, { fallback: true })];
