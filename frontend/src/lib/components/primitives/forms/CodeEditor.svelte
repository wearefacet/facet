<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	/**
	 * CodeEditor — a CodeMirror 6 editor for code/markdown content.
	 *
	 * Provides a form-field appearance (label, helper, error, focus ring)
	 * matching the design system, with a language badge for context.
	 *
	 * Under the hood it uses `svelte-codemirror-editor` wrapping CodeMirror 6.
	 * Lua is highlighted via `@codemirror/legacy-modes` (stream parser).
	 * Markdown uses `@codemirror/lang-markdown` with fenced-code highlighting.
	 * Other languages (json, yaml, html, css, javascript, sql, shell, …)
	 * are loaded on demand from `@codemirror/language-data`.
	 *
	 * ```svelte
	 * <CodeEditor bind:value language="lua" label="Script" />
	 * ```
	 */
	import CodeMirror from 'svelte-codemirror-editor';
	import { LanguageSupport, StreamLanguage } from '@codemirror/language';
	import { lua } from '@codemirror/legacy-modes/mode/lua';
	import { markdown, markdownLanguage } from '@codemirror/lang-markdown';
	import { languages } from '@codemirror/language-data';

	import type { ThemeSpec } from 'svelte-codemirror-editor';
	import { HighlightStyle, type TagStyle } from '@codemirror/language';
	import { tags as t } from '@lezer/highlight';
	import { Maximize2, Minimize2 } from '@lucide/svelte';
	import * as m from '$lib/paraglide/messages';
	import Field from './Field.svelte';
	import { expandable } from '../expandable.js';
	import '../shared.css';

	let {
		/**
		 * The editable content. Two-way bindable via `bind:value`.
		 */
		value = $bindable(''),
		/** Optional label displayed above the editor. */
		label,
		/**
		 * Language identifier used for syntax highlighting and the badge.
		 * Known values: lua, markdown, md, json, yaml, plain, html,
		 * css, javascript, typescript, sql, shell.
		 * Unknown values are resolved via `@codemirror/language-data`.
		 */
		language = 'plain',
		/** Placeholder text shown when empty. */
		placeholder,
		disabled = false,
		readonly = false,
		/** Helper text shown below the editor (hidden when error is set). */
		helper,
		/** Error text shown below the editor with error styling. */
		error,
		/** CSS min-height for the editor area (default 200px). */
		minHeight = '200px',
		/** Explicit id for the textarea (auto-derived from label if omitted). */
		id,
		/** Whether the editor is expanded to fill the page. Two-way bindable. */
		expanded = $bindable(false),
		oninput
	}: {
		value?: string;
		label?: string;
		language?: string;
		placeholder?: string;
		disabled?: boolean;
		readonly?: boolean;
		helper?: string;
		error?: string;
		minHeight?: string;
		id?: string;
		expanded?: boolean;
		oninput?: (e: Event) => void;
	} = $props();

	const hasError = $derived(Boolean(error));
	const editorId = $derived(id ?? (label ? `code-${label}` : undefined));

	/* ── Language badge ───────────────────────── */
	/* ── Language badge ─────────────────────────────────── */
	const languageDisplay: Record<string, string> = {
		lua: 'Lua',
		markdown: 'Markdown',
		md: 'Markdown',
		json: 'JSON',
		yaml: 'YAML',
		plain: 'Text',
		html: 'HTML',
		css: 'CSS',
		javascript: 'JavaScript',
		typescript: 'TypeScript',
		sql: 'SQL',
		shell: 'Shell'
	};
	const badge = $derived(languageDisplay[language] ?? language);
	const isCode = $derived(!['markdown', 'md', 'plain', 'text'].includes(language));

	/* ── Synchronous language extension for Lua ────────── */
	const LUA_LANG = new LanguageSupport(StreamLanguage.define(lua));
	const MD_LANG = markdown({
		base: markdownLanguage,
		codeLanguages: languages
	});

	/* ── Syntax highlighting palette ───────────────────── */
	const syntaxPalette: TagStyle[] = [
		{ tag: t.keyword, color: '#c678dd' },
		{ tag: [t.string, t.special(t.string)], color: '#98c379' },
		{ tag: [t.number, t.bool, t.null], color: '#d19a66' },
		{ tag: t.comment, color: '#7a8794', fontStyle: 'italic' },
		{ tag: t.function(t.variableName), color: '#61afef' },
		{ tag: t.function(t.definition(t.variableName)), color: '#61afef' },
		{ tag: t.className, color: '#e5c07b' },
		{ tag: t.propertyName, color: '#e5c07b' },
		{ tag: t.attributeName, color: '#e5c07b' },
		{ tag: t.typeName, color: '#e5c07b' },
		{ tag: t.modifier, color: '#abb2bf' },
		{ tag: t.operator, color: '#abb2bf' },
		{ tag: t.punctuation, color: '#abb2bf' },
		{ tag: t.bracket, color: '#abb2bf' },
		{ tag: t.meta, color: '#7a8794' },
		{ tag: t.variableName, color: '#e06c75' },
		{ tag: t.self, color: '#e06c75' },
		{ tag: t.labelName, color: '#e06c75' },
		{ tag: t.regexp, color: '#98c379' },
		{ tag: t.link, color: '#61afef', textDecoration: 'underline' },
		{ tag: t.heading, color: '#e06c75', fontWeight: 'bold' },
		{ tag: t.emphasis, fontStyle: 'italic' },
		{ tag: t.strong, fontWeight: 'bold' },
		{ tag: t.strikethrough, textDecoration: 'line-through' },
		{ tag: t.inserted, color: '#98c379' },
		{ tag: t.deleted, color: '#e06c75' },
		{ tag: t.changed, color: '#d19a66' }
	];
	const syntaxHighlight = HighlightStyle.define(syntaxPalette);

	/* ── Resolved language extension ────────────────────── */
	let langExt = $derived.by((): LanguageSupport | undefined => {
		switch (language) {
			case 'lua':
				return LUA_LANG;
			case 'markdown':
			case 'md':
				return MD_LANG;
			case 'plain':
			case 'text':
				return undefined;
			default:
				return asyncLang;
		}
	});

	/* ── Load languages on demand ───────────────────────── */
	let asyncLang = $state<LanguageSupport | undefined>(undefined);

	$effect(() => {
		const code = language;
		if (['lua', 'markdown', 'md', 'plain', 'text'].includes(code)) {
			asyncLang = undefined;
			return;
		}

		asyncLang = undefined;
		const desc = languages.find((l) => l.name.toLowerCase() === code || l.alias.includes(code));
		if (!desc) return;

		let active = true;
		desc.load().then((ls) => {
			if (active) asyncLang = ls;
		});

		return () => {
			active = false;
		};
	});

	/* ── Theme: match the design system tokens ──────────── */
	const editorMinHeight = $derived(expanded ? '100%' : minHeight);

	const editorTheme: ThemeSpec = $derived({
		'&': {
			height: 'auto',
			minHeight: editorMinHeight,
			fontSize: '13px',
			borderRadius: 'var(--r)',
			border: '1px solid var(--border)',
			backgroundColor: 'var(--surface)',
			transition: 'border-color 0.12s, box-shadow 0.12s'
		},
		'&.cm-focused': {
			borderColor: hasError ? 'var(--danger)' : 'var(--accent)',
			outline: 'none',
			boxShadow: hasError ? '0 0 0 3px var(--danger-weak)' : '0 0 0 3px var(--accent-weak)'
		},
		'.cm-scroller': {
			fontFamily: isCode ? 'var(--font-mono)' : 'var(--font-sans, inherit)',
			lineHeight: '1.6',
			fontVariantLigatures: isCode ? 'none' : 'normal',
			padding: '0'
		},
		'.cm-content': {
			padding: '8px 4px',
			caretColor: 'var(--text)'
		},
		'.cm-line': {
			padding: '0 8px'
		},
		'.cm-gutters': {
			backgroundColor: 'var(--sunken, var(--surface-2))',
			borderRight: '1px solid var(--border)',
			color: 'var(--text-3)'
		},
		'.cm-activeLineGutter': {
			backgroundColor: 'var(--accent-weak, transparent)'
		},
		'.cm-selectionBackground': {
			backgroundColor: 'var(--accent-weak)'
		},
		'&.cm-focused .cm-selectionBackground': {
			backgroundColor: 'var(--accent-weak)'
		},
		'.cm-cursor': {
			borderLeftColor: 'var(--text)',
			borderLeftWidth: '2px'
		},
		'&.cm-focused .cm-cursor': {
			borderLeftColor: 'var(--accent)'
		},
		'.cm-placeholder': {
			color: 'var(--text-3)',
			fontStyle: 'normal',
			padding: '0 8px'
		},
		'.cm-matchingBracket': {
			backgroundColor: 'var(--accent-weak)',
			outline: '1px solid var(--accent)'
		},
		'&.cm-editor': {
			borderColor: hasError ? 'var(--danger)' : 'var(--border)'
		}
	});
</script>

{#if expanded}
	<!-- Scrim is a sibling of the panel root, never a child — see shared.css. -->
	<!-- svelte-ignore a11y_click_events_have_key_events -->
	<!-- svelte-ignore a11y_no_static_element_interactions -->
	<div class="fullscreen-overlay" onclick={() => (expanded = false)}></div>
{/if}

<div
	class="code-wrap"
	class:code-error={hasError}
	class:code-disabled={disabled}
	class:code-expanded={expanded}
	class:fullscreen-panel={expanded}
	use:expandable={{ active: expanded, onescape: () => (expanded = false) }}
	role={expanded ? 'dialog' : undefined}
	aria-modal={expanded ? true : undefined}
	aria-label={expanded ? m.common_editor_expanded_aria() : undefined}
>
	<Field {label} {helper} {error} id={editorId ?? undefined} forId={editorId ?? undefined}>
		<div class="code-field-wrap" class:code-field-expanded={expanded}>
			{#key language}
				<CodeMirror
					bind:value
					lang={langExt}
					{placeholder}
					editable={!disabled && !readonly}
					readonly={readonly || disabled}
					lineWrapping={!isCode}
					lineNumbers={isCode}
					useTab={isCode}
					tabSize={2}
					foldGutter={false}
					autocompletion={false}
					closeBrackets={isCode}
					bracketMatching={isCode}
					styles={editorTheme}
					extensions={[]}
					syntaxHighlighting={{ highlighter: syntaxHighlight, fallback: true }}
					onchange={(_v: string) => {
						if (oninput) oninput(new Event('input'));
					}}
				/>
			{/key}

			<div class="code-top-bar">
				{#if !disabled && !readonly}
					<button
						class="code-expand-btn"
						onclick={() => (expanded = !expanded)}
						aria-label={expanded ? m.common_editor_collapse_aria() : m.common_editor_expand_aria()}
						title={expanded ? m.common_editor_collapse() : m.common_editor_expand()}
					>
						{#if expanded}
							<Minimize2 size={12} />
						{:else}
							<Maximize2 size={12} />
						{/if}
					</button>
				{/if}
				<span class="code-badge">{badge}</span>
			</div>
		</div>
	</Field>
</div>

<style>
	/* ── Wrap ─────────────────────────────────────────── */
	.code-wrap {
		display: flex;
		flex-direction: column;
		gap: 5px;
	}

	.code-disabled {
		opacity: 0.5;
		cursor: not-allowed;
	}

	/* Label, helper and error text render through the shared Field component. */

	/* ── Field wrap ────────────────────────── */
	/* ── Field wrap ────────────────────────────────────────── */
	.code-field-wrap {
		display: flex;
		flex-direction: column;
		position: relative;
	}

	/* ── CodeMirror editor within field wrap ───────────────── */
	.code-field-wrap :global(.cm-editor) {
		padding-top: 22px; /* room for badge */
	}

	/* ── Disabled state overlay ────────────────────────────── */
	.code-disabled .code-field-wrap :global(.cm-editor) {
		pointer-events: none;
	}

	.code-disabled .code-field-wrap :global(.cm-content) {
		opacity: 0.7;
	}

	/* ── Top bar (badge + expand button) ───────────────────── */
	.code-top-bar {
		position: absolute;
		top: 6px;
		right: 8px;
		display: flex;
		align-items: center;
		gap: 3px;
		z-index: 1;
	}

	/* ── Expand toggle button ────────────────────────────────── */
	.code-expand-btn {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: 20px;
		height: 20px;
		border: 1px solid var(--border);
		border-radius: var(--r-sm);
		background: var(--surface);
		color: var(--text-3);
		cursor: pointer;
		padding: 0;
		font: inherit;
		transition:
			background 0.12s,
			color 0.12s,
			border-color 0.12s;
	}

	.code-expand-btn:hover {
		background: var(--sunken);
		color: var(--text);
		border-color: var(--border-strong);
	}

	.code-expand-btn:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 1px;
	}

	/* ── Language badge ────────────────────────────────────── */
	.code-badge {
		font-family: var(--font-mono);
		font-size: 10px;
		font-weight: 600;
		letter-spacing: 0.08em;
		text-transform: uppercase;
		color: var(--text-3);
		background: var(--sunken);
		padding: 2px 8px;
		border-radius: var(--r-sm);
		border: 1px solid var(--border);
		line-height: 1.5;
		pointer-events: none;
		user-select: none;
	}

	/* ── Expanded state — overlay the page ──────────────────── */
	/* ── Expanded state — shell (scrim, placement, animation) comes from the shared overlay classes */
	.code-expanded .code-field-expanded {
		flex: 1;
		min-height: 0;
	}

	.code-expanded .code-field-expanded :global(.cm-editor) {
		min-height: 0 !important;
		height: 100%;
		border: 1px solid var(--border);
	}

	.code-expanded .code-field-expanded :global(.cm-scroller) {
		height: 100%;
	}

	.code-expanded .code-field-wrap {
		padding: 6px 6px 6px 6px;
	}

	/* ── Error state — overrides CM focus ring to danger ───── */
	.code-error .code-field-wrap :global(.cm-editor) {
		border-color: var(--danger);
	}

	.code-error .code-field-wrap :global(.cm-focused) {
		box-shadow: 0 0 0 3px var(--danger-weak);
	}
</style>
