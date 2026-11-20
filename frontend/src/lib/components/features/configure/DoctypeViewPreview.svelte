<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import DocumentViewTemplate from '$lib/components/features/document-view/DocumentViewTemplate.svelte';
	import Card from '$lib/components/primitives/content/Card.svelte';
	import {
		previewDocument,
		defaultViewTemplate,
		type ViewKind
	} from '$lib/doctype/previewDocument.js';
	import type { TemplateNode } from '$lib/template-types';
	import type { DoctypeDef } from '$lib/doctype/types.js';
	import type { DocumentResponse } from '$lib/datasource/types';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import * as m from '$lib/paraglide/messages';

	/**
	 * Builds the chrome (frame) for a given `core.DocumentView` kind and renders
	 * a `core.DocumentView` template (or a default fallback) against a mocked
	 * document. The mock is generated from the doctype definition so previews
	 * work without hitting the backend.
	 *
	 * The five kinds map to four chrome variants that match the slice of the
	 * design each kind represents. Reference fields render as plain-text
	 * qualified ids (no hydration in v1).
	 */
	let {
		def,
		views,
		kind,
		driver
	}: {
		/** The doctype definition the views belong to. */
		def: DoctypeDef;
		/**
		 * View templates keyed by `kind`. A kind present in `VIEW_KINDS` but
		 * absent here renders the default fallback template so the user can see
		 * what they would start from.
		 */
		views: Partial<Record<ViewKind, TemplateNode | null>>;
		/** The kind to render in this preview pane. */
		kind: ViewKind;
		/**
		 * Driver used by the `form` preview so input nodes render as editable
		 * controls (reference inputs need it for search/hydration).
		 */
		driver?: DataDriver;
	} = $props();

	const doc = $derived(previewDocument(def));

	const template = $derived.by<TemplateNode>(() => {
		const found = views[kind];
		if (found) return found;
		return defaultViewTemplate(def);
	});

	const isDefined = $derived(views[kind] != null);
	const isForm = $derived(kind === 'form');

	// Editable values bag for the `form` preview. Input nodes bind to this
	// object and self-seed from the mock document content on first render, so
	// the preview shows the same editable controls as the real form surface.
	// Only the `form` kind gets a bag — display kinds render read-only.
	const formValues = $state<Record<string, unknown>>({});
	const isQuickView = $derived(kind === 'quickView');
	const isCard = $derived(kind === 'card');
	const isInline = $derived(kind === 'inline');

	const headerLabel = $derived(doc.meta.display_name ?? `${def.domain}.${def.doctype}`);

	/** Map a view kind to a one-sentence description shown in the preview header. */
	function chromeLegend(k: ViewKind): string {
		// `{id}` in the route patterns is literal documentation text, not a
		// value — pass it through the param verbatim so the catalogue keeps
		// the route shape and the render stays byte-identical.
		switch (k) {
			case 'view':
				return m.configure_doctypes_legend_view({ pattern: '{id}' });
			case 'form':
				return m.configure_doctypes_legend_form({ pattern: '{id}' });
			case 'inline':
				return m.configure_doctypes_legend_inline();
			case 'card':
				return m.configure_doctypes_legend_card();
			case 'quickView':
				return m.configure_doctypes_legend_quickview();
		}
	}
</script>

<div class="preview-pane" data-kind={kind}>
	<header class="preview-head">
		<span class="kind-token">{kind}</span>
		{#if isDefined}
			<span class="badge defined" title={m.configure_doctypes_badge_defined_aria()}
				>{m.configure_doctypes_badge_defined()}</span
			>
		{:else}
			<span class="badge fallback" title={m.configure_doctypes_badge_fallback_aria()}
				>{m.configure_doctypes_badge_fallback()}</span
			>
		{/if}
		<span class="legend">{chromeLegend(kind)}</span>
	</header>

	<div class="chrome-wrap">
		{#if isForm}
			<!-- The form shares the show-page chrome; input nodes render editable
			     controls because they receive the `values` bag + driver. -->
			<div class="chrome chrome-view">
				<div class="doctype-header">
					<span class="dt-id" style="--tint: var(--accent)">{def.doctype}</span>
					<span class="dt-title" title={headerLabel}>{headerLabel}</span>
				</div>
				<div class="chrome-body">
					<DocumentViewTemplate
						{template}
						document={doc as DocumentResponse}
						values={formValues}
						{driver}
						{def}
					/>
				</div>
			</div>
		{:else if isQuickView}
			<!-- Narrow sidebar chrome — matches the peek drawer width. -->
			<div
				class="chrome chrome-quickview"
				role="complementary"
				aria-label={m.configure_doctypes_quickview_preview_aria()}
			>
				<div class="qv-head">
					<span class="qv-id" style="--tint: var(--accent)">{def.doctype}</span>
					<span class="qv-title" title={headerLabel}>{headerLabel}</span>
				</div>
				<div class="qv-body">
					<DocumentViewTemplate {template} document={doc as DocumentResponse} {def} />
				</div>
			</div>
		{:else if isCard}
			<!-- Kanban card chrome — narrow width, Card.svelte shell. -->
			<div class="chrome chrome-card">
				<Card doctype="document">
					<DocumentViewTemplate {template} document={doc as DocumentResponse} {def} />
				</Card>
			</div>
		{:else if isInline}
			<!-- Inline row chrome — a single table-row context. -->
			<div class="chrome chrome-inline">
				<table class="inline-table">
					<thead>
						<tr><th>{m.configure_doctypes_inline_preview()}</th></tr>
					</thead>
					<tbody>
						<tr>
							<td>
								<DocumentViewTemplate {template} document={doc as DocumentResponse} {def} />
							</td>
						</tr>
					</tbody>
				</table>
			</div>
		{:else}
			<!-- `view` kind — full-page show chrome. -->
			<div class="chrome chrome-view">
				<div class="doctype-header">
					<span class="dt-id" style="--tint: var(--accent)">{def.doctype}</span>
					<span class="dt-title" title={headerLabel}>{headerLabel}</span>
				</div>
				<div class="chrome-body">
					<DocumentViewTemplate {template} document={doc as DocumentResponse} {def} />
				</div>
			</div>
		{/if}
	</div>
</div>

<style>
	.preview-pane {
		display: flex;
		flex-direction: column;
		gap: 12px;
		height: 100%;
		min-height: 0;
	}

	.preview-head {
		display: flex;
		align-items: center;
		gap: 8px;
		flex: none;
		padding: 8px 12px;
		border-bottom: 1px solid var(--border);
		background: var(--surface-2);
	}

	.kind-token {
		font-family: var(--font-mono);
		font-size: 12px;
		font-weight: 700;
		color: var(--text);
		background: var(--sunken);
		border-radius: var(--r-sm);
		padding: 2px 7px;
	}

	.badge {
		font-size: 10.5px;
		font-weight: 600;
		letter-spacing: 0.04em;
		text-transform: uppercase;
		padding: 1px 7px;
		border-radius: var(--r-pill);
	}

	.badge.defined {
		color: var(--ok);
		background: color-mix(in srgb, var(--ok) 14%, transparent);
	}

	.badge.fallback {
		color: var(--text-3);
		background: var(--sunken);
	}

	.legend {
		margin-left: auto;
		font-size: 12px;
		color: var(--text-3);
		font-style: italic;
	}

	.chrome-wrap {
		flex: 1;
		min-height: 0;
		overflow: auto;
		padding: 16px;
		background: var(--sunken);
	}

	/* ── Show-page / form chrome ─────────────────────────────────────────── */
	.chrome-view {
		max-width: 880px;
		margin: 0 auto;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: var(--sh-1);
		overflow: hidden;
	}

	.doctype-header {
		display: flex;
		align-items: baseline;
		gap: 10px;
		padding: 14px 20px;
		border-bottom: 1px solid var(--border);
		background: var(--surface-2);
	}

	.dt-id {
		font-family: var(--font-mono);
		font-size: 11.5px;
		font-weight: 700;
		color: var(--tint);
		background: color-mix(in srgb, var(--tint) 12%, transparent);
		border-radius: var(--r-sm);
		padding: 1px 6px;
	}

	.dt-title {
		font-family: var(--font-display);
		font-size: 17px;
		font-weight: 600;
		color: var(--text);
		min-width: 0;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.chrome-body {
		padding: 20px;
	}

	/* ── QuickView chrome ────────────────────────────────────────────────── */
	.chrome-quickview {
		width: 340px;
		max-width: 100%;
		margin: 0 auto;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: var(--sh-1);
		overflow: hidden;
	}

	.qv-head {
		display: flex;
		flex-direction: column;
		gap: 4px;
		padding: 12px 14px;
		border-bottom: 1px solid var(--border);
		background: var(--surface-2);
	}

	.qv-id {
		font-family: var(--font-mono);
		font-size: 10.5px;
		font-weight: 700;
		color: var(--tint);
	}

	.qv-title {
		font-family: var(--font-display);
		font-size: 14px;
		font-weight: 600;
		color: var(--text);
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.qv-body {
		padding: 12px 14px;
	}

	/* ── Card chrome ─────────────────────────────────────────────────────── */
	.chrome-card {
		width: 260px;
		max-width: 100%;
		margin: 0 auto;
	}

	/* ── Inline chrome ───────────────────────────────────────────────────── */
	.chrome-inline {
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		overflow: hidden;
	}

	.inline-table {
		width: 100%;
		border-collapse: collapse;
	}

	.inline-table th {
		text-align: left;
		font-size: 11px;
		font-weight: 600;
		letter-spacing: 0.05em;
		text-transform: uppercase;
		color: var(--text-3);
		padding: 8px 14px;
		background: var(--surface-2);
		border-bottom: 1px solid var(--border);
	}

	.inline-table td {
		padding: 12px 14px;
		vertical-align: top;
	}
</style>
