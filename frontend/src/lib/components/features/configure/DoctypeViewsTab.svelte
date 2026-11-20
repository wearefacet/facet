<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import DoctypeViewPreview from './DoctypeViewPreview.svelte';
	import { VIEW_KINDS, defaultViewTemplate, type ViewKind } from '$lib/doctype/previewDocument.js';
	import {
		createDocumentView,
		updateDocumentView,
		type ViewTemplate
	} from '$lib/doctype/viewAuthoring.js';
	import { doctypeViewsCache } from '$lib/datasource/clientCache.js';
	import { errorMessage } from '$lib/datasource/bannerError.js';
	import { can } from '$lib/permissions.svelte';
	import type { TemplateNode } from '$lib/template-types.js';
	import type { DoctypeDef } from '$lib/doctype/types.js';
	import type { DoctypeDefinitionRegistry } from '$lib/datasource/DoctypeRegistry.js';
	import * as m from '$lib/paraglide/messages';

	/**
	 * Views tab of the doctype editor.
	 *
	 * A nav of the five `core.DocumentView` kinds with defined/fallback badges
	 * and a pane that previews the selected kind. The preview is the default
	 * mode; the Edit mode swaps it for a plain JSON textarea holding the
	 * view's `template` object. Save validates the JSON locally, then creates
	 * the missing view or PATCHes the stored one (`viewIds` carries the child
	 * id per kind).
	 *
	 * The Edit affordance is a UI hint: it renders only when the caller may
	 * write `core.DocumentView` and the editor is not read-only (a published
	 * domain in the Configure shell is read-only). The backend re-checks every
	 * write. The empty-state note follows the same gate: it names Edit only
	 * when Edit is on screen.
	 */
	let {
		def,
		views,
		viewIds = {},
		registry,
		qualifiedName,
		readonly = false,
		selectedViewKind,
		onselect,
		onsaved,
		saveView
	}: {
		/** The doctype definition the previews are generated from. */
		def: DoctypeDef;
		/** `core.DocumentView` templates keyed by kind; absent kinds fall back. */
		views: Partial<Record<ViewKind, TemplateNode | null>>;
		/** `core.DocumentView` child ids keyed by kind — absent means create. */
		viewIds?: Partial<Record<ViewKind, string>>;
		/** Driver for the `form` preview's editable reference inputs. */
		registry: DoctypeDefinitionRegistry;
		/** Qualified doctype name — the parent of the view documents. */
		qualifiedName: string;
		/** Published domain: the views render read-only. */
		readonly?: boolean;
		/** The kind shown in the preview pane (parent-owned, URL-backed). */
		selectedViewKind: ViewKind;
		/** Select a kind — the parent syncs the `?view=` query param. */
		onselect: (kind: ViewKind) => void;
		/** Called after a successful save with the views and child ids now
		 *  stored, so the parent (tab badge, next load) reflects the write
		 *  without a reload. */
		onsaved?: (
			views: Partial<Record<ViewKind, TemplateNode | null>>,
			viewIds: Partial<Record<ViewKind, string>>
		) => void;
		/** Write seam: storybook injects a fake, the app uses the REST routes.
		 *  Returns the child id on a create so the next save PATCHes instead of
		 *  creating a duplicate of the same kind; `undefined` on an update. */
		saveView?: (
			parentDoctype: string,
			kind: ViewKind,
			template: ViewTemplate,
			id?: string
		) => Promise<string | undefined>;
	} = $props();

	/** True when at least one kind holds a stored template. When none does,
	 *  the nav shows the authoring note. */
	const hasDefinedLocal = $derived(VIEW_KINDS.some((kind) => localViews[kind] != null));

	const canWrite = $derived(
		!readonly && (can('core.DocumentView', 'create') || can('core.DocumentView', 'update'))
	);

	// ── Local copies of the loaded views ────────────────────────────────────
	// A save updates these so the preview reflects the new template without a
	// round-trip. The effect below seeds them from the props and re-seeds when
	// the route reloads (a new `views` / `viewIds` object arrives). Raw state:
	// the maps are replaced wholesale, never mutated in place.
	let localViews = $state.raw<Partial<Record<ViewKind, TemplateNode | null>>>({});
	let localIds = $state.raw<Partial<Record<ViewKind, string>>>({});

	$effect(() => {
		const next = views;
		const nextIds = viewIds;
		localViews = { ...next };
		localIds = { ...nextIds };
	});

	// ── Edit mode ───────────────────────────────────────────────────────────
	let mode = $state<'display' | 'edit'>('display');
	let draft = $state('');
	let saving = $state(false);
	let jsonError = $state<string | null>(null);
	let saveError = $state<string | null>(null);

	/** The stored template of a kind, or the definition-generated fallback. */
	function templateOf(kind: ViewKind): ViewTemplate {
		const stored = localViews[kind];
		if (stored) return stored as unknown as ViewTemplate;
		return defaultViewTemplate(def) as unknown as ViewTemplate;
	}

	function startEdit() {
		draft = JSON.stringify(templateOf(selectedViewKind), null, 2);
		jsonError = null;
		saveError = null;
		mode = 'edit';
	}

	function cancelEdit() {
		mode = 'display';
		jsonError = null;
		saveError = null;
	}

	/** Route the write: PATCH the stored child, or create the missing one. */
	async function defaultSaveView(
		parentDoctype: string,
		kind: ViewKind,
		template: ViewTemplate,
		id?: string
	): Promise<string | undefined> {
		const { apiFetch } = await import('$lib/session.svelte');
		if (id) {
			await updateDocumentView(apiFetch, parentDoctype, id, template);
			return undefined;
		}
		return createDocumentView(apiFetch, parentDoctype, kind, template);
	}

	async function save() {
		if (saving) return;
		jsonError = null;
		saveError = null;

		let parsed: unknown;
		try {
			parsed = JSON.parse(draft);
		} catch (err) {
			jsonError = m.configure_doctypes_views_invalid_json({ message: errorMessage(err) });
			return;
		}
		if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
			jsonError = m.configure_doctypes_views_invalid_json({
				message: m.configure_doctypes_views_template_not_object()
			});
			return;
		}

		const kind = selectedViewKind;
		const template = parsed as ViewTemplate;
		saving = true;
		try {
			const createdId = await (saveView ?? defaultSaveView)(
				qualifiedName,
				kind,
				template,
				localIds[kind]
			);
			localViews = { ...localViews, [kind]: template as unknown as TemplateNode };
			// A create yields a fresh child id: remember it so a second save
			// PATCHes the stored row instead of creating a duplicate kind.
			if (createdId) localIds = { ...localIds, [kind]: createdId };
			// Invalidate the TTL entry so a reload does not serve the stale
			// children list.
			doctypeViewsCache.invalidate(qualifiedName);
			// Hand the stored maps to the parent: its Views badge derives from
			// the `views` prop, which a tab switch does not reload.
			onsaved?.(localViews, localIds);
			mode = 'display';
		} catch (err) {
			saveError = m.configure_doctypes_views_save_error({ message: errorMessage(err) });
		} finally {
			saving = false;
		}
	}
</script>

<div class="views-layout">
	<nav class="views-nav" aria-label={m.configure_doctypes_view_kinds_aria()}>
		{#each VIEW_KINDS as kind (kind)}
			<button
				class:on={selectedViewKind === kind}
				onclick={() => {
					mode = 'display';
					onselect(kind);
				}}
			>
				<span class="vk">{kind}</span>
				{#if localViews[kind] != null}
					<span class="badge defined">{m.configure_doctypes_badge_defined()}</span>
				{:else}
					<span class="badge fallback">{m.configure_doctypes_badge_fallback()}</span>
				{/if}
			</button>
		{/each}
		{#if !hasDefinedLocal}
			<p class="views-empty">
				{canWrite
					? m.configure_doctypes_views_empty_hint()
					: m.configure_doctypes_views_empty_hint_readonly()}
			</p>
		{/if}
	</nav>
	<div class="views-pane">
		{#if mode === 'display'}
			<div class="views-toolbar">
				{#if canWrite}
					<div class="mode-switch" role="group" aria-label={m.configure_doctypes_views_mode_aria()}>
						<button class="on" type="button" aria-pressed="true">
							{m.configure_doctypes_views_display_button()}
						</button>
						<button type="button" aria-pressed="false" onclick={startEdit}>
							{m.configure_doctypes_views_edit_button()}
						</button>
					</div>
				{/if}
			</div>
			<div class="views-preview">
				<DoctypeViewPreview {def} views={localViews} kind={selectedViewKind} driver={registry} />
			</div>
		{:else}
			<div class="views-editor">
				<label class="editor-label" for="dvt-template-json">
					{m.configure_doctypes_views_json_label({ kind: selectedViewKind })}
				</label>
				<textarea
					id="dvt-template-json"
					class="editor-input"
					spellcheck="false"
					autocapitalize="off"
					autocomplete="off"
					bind:value={draft}></textarea>
				{#if jsonError}
					<p class="editor-error" role="alert">{jsonError}</p>
				{/if}
				{#if saveError}
					<p class="editor-error" role="alert">{saveError}</p>
				{/if}
				<div class="editor-actions">
					<button class="btn-cancel" type="button" disabled={saving} onclick={cancelEdit}>
						{m.common_cancel()}
					</button>
					<button class="btn-save" type="button" disabled={saving} onclick={save}>
						{saving ? m.common_saving() : m.common_save()}
					</button>
				</div>
			</div>
		{/if}
	</div>
</div>

<style>
	.views-layout {
		display: grid;
		grid-template-columns: 220px 1fr;
		height: 100%;
		min-height: 0;
		overflow: hidden;
	}

	.views-nav {
		display: flex;
		flex-direction: column;
		gap: 4px;
		padding: 12px;
		border-right: 1px solid var(--border);
		background: var(--surface-2);
		overflow-y: auto;
	}

	.views-nav button {
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 8px 10px;
		border-radius: var(--r-sm);
		border: 1px solid transparent;
		background: transparent;
		color: var(--text);
		font: inherit;
		font-size: 13px;
		cursor: pointer;
		text-align: left;
	}

	.views-nav button:hover {
		background: var(--sunken);
	}

	.views-nav button.on {
		background: color-mix(in srgb, var(--accent) 12%, transparent);
		border-color: color-mix(in srgb, var(--accent) 30%, transparent);
	}

	.views-nav .vk {
		font-family: var(--font-mono);
		font-size: 12px;
		font-weight: 700;
	}

	.badge {
		font-size: 10.5px;
		font-weight: 600;
		padding: 1px 7px;
		border-radius: var(--r-pill);
		border: 1px solid var(--border);
		background: var(--sunken);
		letter-spacing: 0.02em;
	}

	.views-nav .badge {
		margin-left: auto;
		font-size: 10px;
		font-weight: 600;
		letter-spacing: 0.04em;
		text-transform: uppercase;
		padding: 1px 6px;
		border-radius: var(--r-pill);
	}

	.views-nav .badge.defined {
		color: var(--ok);
		background: color-mix(in srgb, var(--ok) 14%, transparent);
	}

	.views-nav .badge.fallback {
		color: var(--text-3);
		background: var(--sunken);
	}

	/* Authoring note for the empty state — the tab previews a fallback. */
	.views-empty {
		margin: 10px 2px 0;
		padding-top: 10px;
		border-top: 1px solid var(--border);
		font-size: 12px;
		line-height: 1.5;
		color: var(--text-2);
	}

	.views-pane {
		display: flex;
		flex-direction: column;
		min-width: 0;
		min-height: 0;
	}

	.views-toolbar {
		display: flex;
		justify-content: flex-end;
		padding: 8px 12px;
		border-bottom: 1px solid var(--border);
	}

	.mode-switch {
		display: inline-flex;
		border: 1px solid var(--border);
		border-radius: var(--r-sm);
		overflow: hidden;
	}

	.mode-switch button {
		padding: 4px 12px;
		font: inherit;
		font-size: 12px;
		font-weight: 600;
		color: var(--text-2);
		background: var(--surface);
		border: none;
		cursor: pointer;
	}

	.mode-switch button + button {
		border-left: 1px solid var(--border);
	}

	.mode-switch button:hover {
		background: var(--sunken);
	}

	.mode-switch button.on {
		color: var(--on-accent);
		background: var(--accent);
	}

	.views-preview {
		flex: 1;
		min-width: 0;
		min-height: 0;
		overflow: auto;
	}

	/* ── JSON editor ──────────────────────────────────────────────────────── */
	.views-editor {
		display: flex;
		flex-direction: column;
		gap: 8px;
		flex: 1;
		min-height: 0;
		padding: 12px;
	}

	.editor-label {
		font-size: 12px;
		font-weight: 600;
		color: var(--text-2);
	}

	.editor-input {
		flex: 1;
		min-height: 0;
		resize: none;
		font-family: var(--font-mono);
		font-size: 12.5px;
		line-height: 1.5;
		color: var(--text);
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-sm);
		padding: 10px 12px;
		tab-size: 2;
	}

	.editor-input:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 1px;
	}

	.editor-error {
		margin: 0;
		font-size: 12px;
		color: var(--danger);
	}

	.editor-actions {
		display: flex;
		justify-content: flex-end;
		gap: 8px;
	}

	.editor-actions button {
		padding: 5px 14px;
		font: inherit;
		font-size: 12px;
		font-weight: 600;
		border-radius: var(--r);
		cursor: pointer;
	}

	.editor-actions button:disabled {
		opacity: 0.6;
		cursor: default;
	}

	.btn-cancel {
		color: var(--text);
		background: var(--surface);
		border: 1px solid var(--border-strong);
	}

	.btn-cancel:hover:not(:disabled) {
		background: var(--sunken);
	}

	.btn-save {
		color: var(--on-accent);
		background: var(--accent);
		border: 1px solid var(--accent);
	}

	.btn-save:hover:not(:disabled) {
		background: var(--accent-press);
	}
</style>
