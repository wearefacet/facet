<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	/**
	 * Markdown — renders markdown with the Milkdown WYSIWYG editor in
	 * preview (readonly) and write (editable) modes, or as a raw markdown
	 * source editor (CodeMirror), with a fullscreen expand mode mirroring
	 * `CodeEditor`.
	 *
	 * A segmented control toggles between the three modes. An expand
	 * button opens a `position: fixed` fullscreen overlay containing the
	 * same toolbar + the active view. Closing the overlay (Escape, scrim
	 * click, or collapse button) returns to inline.
	 *
	 * When `value` is provided the component is controlled: both preview
	 * and editor reflect `value`, and edits are surfaced via `onchange`.
	 * Without `value`, an internal buffer seeded from `defaultValue` is used.
	 *
	 * Preview and readonly use the same Milkdown engine as Write mode — one
	 * renderer, so the surfaces cannot drift. Chat bubbles render their own
	 * readonly markdown (`features/chat/Markdown.svelte`); this component
	 * does not cover them.
	 *
	 * Files dropped or pasted in write mode upload to the standalone
	 * artifact service and are referenced as `urn:facet:artifact:<id>` —
	 * images render through the download gateway, links as capsules (see
	 * `$lib/artifacts.ts`). Files are never inlined as data/blob URLs.
	 * `uploadFile` is the injectable uploader for stories.
	 *
	 * ```svelte
	 * <Markdown value={src} onchange={(v) => (src = v)} />
	 * ```
	 */
	import CodeMirror from 'svelte-codemirror-editor';
	import { MD_LANG, sourceEditorExtensions, sourceEditorTheme } from './markdown-source';
	import Milkdown from './Milkdown.svelte';
	import { uploadArtifactAsUrn } from '$lib/artifacts.js';
	import { errorMessage } from '$lib/datasource/bannerError.js';
	import type { PickerSources } from '$lib/referenceSearch.js';
	import type { ReferenceClickHandler } from '$lib/template-types';
	import { Maximize2, Minimize2 } from '@lucide/svelte';
	import { expandable } from '../expandable.js';
	import '../shared.css';

	let {
		value = undefined,
		defaultValue = '',
		mode: initialMode = 'preview',
		readonly = false,
		bare = false,
		placeholder = m.doc_md_placeholder(),
		expanded = $bindable(false),
		onchange,
		empty,
		uploadFile,
		onReferenceClick,
		domain = '',
		sources,
		...rest
	}: {
		/** Controlled markdown source. When set, overrides internal state. */
		value?: string;
		/** Initial value for uncontrolled usage (ignored if `value` is set). */
		defaultValue?: string;
		/** The active editing surface. 'write' is the WYSIWYG (Milkdown)
		 *  editor; 'markdown' is the raw source editor for advanced users. */
		mode?: 'preview' | 'write' | 'markdown';
		/** Read-only: hides the toolbar and renders the preview only. */
		readonly?: boolean;
		/** Chrome-less: no border/background box around the surface (for
		 *  embedding inside a field wrapper that draws its own box). */
		bare?: boolean;
		/** Placeholder shown in the editor when empty. */
		placeholder?: string;
		/** Whether the fullscreen overlay is open. Two-way bindable. */
		expanded?: boolean;
		/** Fired with the new source on edit. */
		onchange?: (value: string) => void;
		/** Rendered in the "preview empty" state. */
		empty?: import('svelte').Snippet;
		/** Injectable uploader — receives a `File` and returns `{ id, filename }`.
		 *  Defaults to a `POST /Api/core/artifacts` call via `apiFetch`. Stories
		 *  pass a synthetic uploader so the play function can assert the
		 *  artifact insertion without a live backend. */
		uploadFile?: (file: File) => Promise<{ id: string; filename: string }>;
		/** Reference-chip click handler for readonly surfaces (the QuickView
		 *  drawer). Forwarded to the editor in both modes; edit mode never
		 *  calls it — a chip click there selects the node. Without a handler
		 *  readonly chips stay static. */
		onReferenceClick?: ReferenceClickHandler;
		/** Current domain segment, or `''` on global pages — scopes the `@`
		 *  reference picker (domain mode vs app-wide escalation) and the empty
		 *  state's recents slice. Callers drill it from the route context. */
		domain?: string;
		/** Injectable data sources for the `@` reference picker and the chip
		 *  label resolver. Defaults to the real services; stories pass synthetic
		 *  bundles. When given, it must carry `resolveLabel` for chips to resolve
		 *  live labels. */
		sources?: PickerSources;
	} = $props();

	// svelte-ignore state_referenced_locally — intentional initial seeding
	let mode = $state<'preview' | 'write' | 'markdown'>(readonly ? 'preview' : initialMode);
	// svelte-ignore state_referenced_locally — intentional initial seeding
	let internal = $state(defaultValue);

	// Upload state — surfaced below the toolbar while a dropped/pasted file
	// is in flight and on failure. The editor's uploader stores files on the
	// standalone artifact route and references them as `urn:facet:artifact:<id>`
	// (images) or `[filename](urn:facet:artifact:<id>)` capsule links — never
	// inlined as data/blob URLs.
	let uploading = $state(false);
	let uploadError = $state<string | null>(null);

	async function uploadArtifact(file: File): Promise<string> {
		uploading = true;
		uploadError = null;
		try {
			return await uploadArtifactAsUrn(file, uploadFile);
		} catch (err) {
			uploadError = errorMessage(err, m.common_upload_failed());
			return '';
		} finally {
			uploading = false;
		}
	}

	const current = $derived(value !== undefined ? value : internal);
	const isEmpty = $derived(current.trim().length === 0);

	function handleEdit(next: string) {
		internal = next;
		onchange?.(next);
	}

	function setMode(next: 'preview' | 'write' | 'markdown') {
		if (readonly) return;
		mode = next;
	}

	function toggleExpanded() {
		expanded = !expanded;
	}
</script>

{#if expanded}
	<!-- Scrim is a sibling of the panel root, never a child — see shared.css. -->
	<!-- svelte-ignore a11y_click_events_have_key_events -->
	<!-- svelte-ignore a11y_no_static_element_interactions -->
	<div class="fullscreen-overlay" onclick={() => (expanded = false)}></div>
{/if}

<div
	class="markdown"
	class:md-bare={bare}
	class:md-readonly={readonly}
	class:md-expanded={expanded}
	class:fullscreen-panel={expanded}
	use:expandable={{ active: expanded, onescape: () => (expanded = false) }}
	role={expanded ? 'dialog' : undefined}
	aria-modal={expanded ? true : undefined}
	aria-label={expanded ? m.doc_md_editor_aria() : undefined}
	{...rest}
>
	<!-- ── Toolbar ─────────────────────────────────────────── -->
	<!-- Readonly inline: no toolbar at all — the expand affordance is a
		hover-revealed floating button in the corner. Readonly expanded:
		keep the slim bar with the collapse button. -->
	{#if !readonly}
		<header class="md-toolbar">
			<div class="seg" role="group" aria-label={m.doc_md_mode_aria()}>
				<button
					type="button"
					class="seg-btn"
					class:seg-btn-on={mode === 'preview'}
					aria-pressed={mode === 'preview'}
					onclick={() => setMode('preview')}
				>
					{m.doc_md_preview()}
				</button>
				<button
					type="button"
					class="seg-btn"
					class:seg-btn-on={mode === 'write'}
					aria-pressed={mode === 'write'}
					onclick={() => setMode('write')}
				>
					{m.doc_md_write()}
				</button>
				<button
					type="button"
					class="seg-btn"
					class:seg-btn-on={mode === 'markdown'}
					aria-pressed={mode === 'markdown'}
					onclick={() => setMode('markdown')}
				>
					{m.doc_md_markdown()}
				</button>
			</div>
			<div class="md-toolbar-actions">
				{#if uploading}
					<span class="md-upload-status" role="status">{m.common_uploading()}</span>
				{/if}
				{#if uploadError}
					<span class="md-upload-error" role="alert">{uploadError}</span>
				{/if}
				<button
					class="md-expand-btn"
					onclick={toggleExpanded}
					aria-label={expanded ? m.doc_md_collapse() : m.doc_md_expand()}
					title={expanded ? m.doc_md_collapse() : m.doc_md_expand()}
				>
					{#if expanded}
						<Minimize2 size={13} />
					{:else}
						<Maximize2 size={13} />
					{/if}
				</button>
			</div>
		</header>
	{:else if expanded}
		<header class="md-toolbar md-toolbar-readonly">
			<div class="md-toolbar-actions">
				<button
					class="md-expand-btn"
					onclick={toggleExpanded}
					aria-label={m.doc_md_collapse()}
					title={m.doc_md_collapse()}
				>
					<Minimize2 size={13} />
				</button>
			</div>
		</header>
	{/if}

	<!-- ── Body ────────────────────────────────────────────── -->
	<div class="md-body" class:md-body-flow={mode === 'write'}>
		{#if mode === 'preview'}
			{#if isEmpty}
				{#if empty}
					{@render empty()}
				{:else}
					<p class="md-empty">{m.doc_md_nothing()}</p>
				{/if}
			{:else}
				<div class="md-editor">
					<Milkdown value={current} readonly {placeholder} {domain} {sources} {onReferenceClick} />
				</div>
			{/if}
		{:else if mode === 'write'}
			<div class="md-editor">
				<Milkdown
					value={current}
					{placeholder}
					onchange={handleEdit}
					onupload={uploadArtifact}
					{domain}
					{sources}
					{onReferenceClick}
				/>
			</div>
		{:else}
			<div class="md-editor">
				<CodeMirror
					value={current}
					{placeholder}
					editable={!readonly}
					lineWrapping
					lang={MD_LANG}
					styles={sourceEditorTheme}
					extensions={sourceEditorExtensions}
					onchange={handleEdit}
				/>
			</div>
		{/if}
	</div>

	<!-- ── Readonly expand affordance ───────────────────────── 
		Hover- (or focus-) revealed corner button — no toolbar row,
		so a readonly preview costs no vertical space. -->
	{#if readonly && !expanded}
		<button
			class="md-expand-float"
			onclick={toggleExpanded}
			aria-label={m.doc_md_expand()}
			title={m.doc_md_expand()}
		>
			<Maximize2 size={12} />
		</button>
	{/if}
</div>

<style>
	.markdown {
		display: flex;
		flex-direction: column;
		min-width: 0;
		/* No `overflow: hidden` — the editor's floating menus mount inside
		 * the editor DOM and must overlay content outside this box. The
		 * toolbar rounds its own top corners to match. */
	}

	/* Inline box + anchor for the readonly floating expand button. Scoped
	 * rules outrank the global `.fullscreen-panel` shell, so every property
	 * the shell owns (fixed placement, surface box) applies only to the
	 * inline state — expanded, the element falls through to the shared
	 * class and anchors to the viewport. */
	.markdown:not(.md-expanded) {
		position: relative;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r);
	}

	/* Bare embedding — the host (e.g. the longtext field wrapper) draws
	 * its own box; this surface contributes none — including the body and
	 * the editor DOM, which otherwise paint their own surface colour.
	 * Expanded, the shared shell box applies. */
	.markdown.md-bare:not(.md-expanded) {
		border: none;
		background: none;
	}

	.md-bare .md-body,
	.md-bare .md-editor :global(.milkdown-host),
	.md-bare .md-editor :global(.cm-editor) {
		background: none;
	}

	/* Crepe paints the inner .milkdown element from its own background
	 * token (mapped to var(--surface) by the wrapper). In a bare embedding
	 * the host draws the box — the token goes transparent so no editor
	 * layer can repaint a surface under the text. */
	.md-bare .md-editor :global(.milkdown-host .milkdown-root .milkdown) {
		--crepe-color-background: transparent;
		background: none;
	}

	/* ── Toolbar ──────────────────────────────────────────────── */
	.md-toolbar {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 10px;
		padding: 7px 9px;
		border-bottom: 1px solid var(--border);
		border-radius: var(--r) var(--r) 0 0;
		background: var(--surface-2);
		flex-shrink: 0;
	}

	/* Readonly toolbar holds only the expand button — keep it right-aligned. */
	.md-toolbar-readonly {
		justify-content: flex-end;
	}

	.seg {
		display: inline-flex;
		padding: 2px;
		background: var(--sunken);
		border-radius: var(--r-sm);
		gap: 2px;
	}

	.seg-btn {
		border: none;
		background: none;
		font: inherit;
		font-size: 11.5px;
		font-weight: 600;
		color: var(--text-2);
		padding: 5px 11px;
		border-radius: 4px;
		cursor: pointer;
		transition:
			background 0.12s,
			color 0.12s;
	}

	.seg-btn:hover {
		color: var(--text);
	}

	.seg-btn-on {
		background: var(--surface);
		color: var(--text);
		box-shadow: var(--sh-1);
	}

	.seg-btn:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 2px;
	}

	.md-toolbar-actions {
		display: inline-flex;
		align-items: center;
		gap: 6px;
	}

	.md-expand-btn {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: 26px;
		height: 26px;
		border: 1px solid var(--border);
		border-radius: var(--r-sm);
		background: var(--surface);
		color: var(--text-3);
		cursor: pointer;
		padding: 0;
		transition:
			background 0.12s,
			color 0.12s,
			border-color 0.12s;
	}

	.md-expand-btn:hover {
		background: var(--sunken);
		color: var(--text);
		border-color: var(--border-strong);
	}

	.md-expand-btn:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 1px;
	}

	/* ── Readonly floating expand button ───────────────────────── */
	.md-expand-float {
		position: absolute;
		top: 6px;
		right: 6px;
		z-index: 2;
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: 22px;
		height: 22px;
		padding: 0;
		border: 1px solid var(--border);
		border-radius: var(--r-sm);
		background: var(--surface);
		color: var(--text-3);
		cursor: pointer;
		opacity: 0;
		transition:
			opacity 0.12s,
			background 0.12s,
			color 0.12s,
			border-color 0.12s;
	}

	/* Silent at rest, discoverable on hover or keyboard focus. */
	.markdown:hover .md-expand-float,
	.md-expand-float:focus-visible {
		opacity: 1;
	}

	.md-expand-float:hover {
		background: var(--sunken);
		color: var(--text);
		border-color: var(--border-strong);
	}

	.md-expand-float:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 1px;
	}

	/* ── Body ─────────────────────────────────────────────────── */
	.md-body {
		flex: 1 1 auto;
		min-height: 0;
		overflow: auto;
		position: relative;
		background: var(--surface);
	}

	/* Write mode: the WYSIWYG editor's floating menus (slash menu, block
	 * handle, toolbar) mount inside the editor DOM — a scroll container here
	 * would clip them. Let the body flow naturally and delegate scrolling
	 * to the page (inline) or the overlay (expanded). */
	.md-body-flow {
		overflow: visible;
	}

	/* ── Inline editor sizing ──────────────────────────────────── */
	.md-editor {
		min-height: 200px;
		height: 100%;
	}

	/* Readonly previews size to their content — a short comment must not
	 * reserve editor-height space. They also never scroll internally: the
	 * surrounding rail/page is the scroll owner, so overflow passes
	 * through to it instead of nesting a second scrollbar. */
	.md-readonly .md-editor {
		min-height: 0;
		height: auto;
	}

	.md-readonly:not(.md-expanded) .md-body {
		overflow: visible;
	}

	.md-editor :global(.cm-editor),
	.md-editor :global(.milkdown-host) {
		height: 100%;
	}

	.md-editor :global(.cm-scroller) {
		overflow: auto;
	}

	/* ── Upload status — in the toolbar actions row ───────────── */
	.md-upload-status {
		font-size: 11px;
		color: var(--text-3);
	}

	.md-upload-error {
		font-size: 11px;
		color: var(--danger);
	}

	/* ── Empty state ──────────────────────────────────────────── */
	.md-empty {
		margin: 0;
		padding: 24px;
		color: var(--text-3);
		font-size: 13px;
	}

	/* ── Expanded overlay — mirrors CodeEditor pattern ─────────── */
	/* ── Expanded overlay — shell (scrim, placement, animation) is shared ── */
	.md-expanded {
		/* Scroll owner for expanded write mode (the body flows visibly so
		 * the editor's floating menus are not clipped). */
		overflow: auto;
	}

	.md-expanded .md-toolbar {
		border-radius: var(--r-lg) var(--r-lg) 0 0;
		/* Stay pinned while the overlay scrolls. */
		position: sticky;
		top: 0;
		z-index: 1;
	}

	.md-expanded .md-body {
		flex: 1;
		min-height: 0;
	}

	.md-expanded .md-editor {
		height: 100%;
		/* Reader feel: cap the content column and centre it, so a full-size
		 * document reads like a page instead of stretching edge to edge. The
		 * toolbar keeps the full overlay width. */
		max-width: 800px;
		margin: 0 auto;
	}
</style>
