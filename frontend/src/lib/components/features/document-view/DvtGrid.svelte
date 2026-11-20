<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import DocumentViewTemplate from './DocumentViewTemplate.svelte';
	import { parseGridLayout } from '$lib/template-resolve';
	import type { GridNode, ReferenceClickHandler } from '$lib/template-types';
	import type { DocumentResponse } from '$lib/datasource/types';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { DoctypeDef } from '$lib/doctype/types.js';
	import type { FieldErrorMap } from '$lib/doctype/fieldErrors.js';
	import type { FieldStageRegistrar } from './fieldStage.js';

	let {
		template,
		document,
		values,
		driver,
		def,
		fieldErrors,
		registerFieldStage,
		onreferenceclick,
		historyHref,
		...rest
	}: {
		/** The grid template node. */
		template: GridNode;
		/** The full document response. */
		document: DocumentResponse;
		values?: Record<string, unknown>;
		/** Driver forwarded to children for reference hydration. */
		driver?: DataDriver;
		/** Doctype definition forwarded to children. */
		def?: DoctypeDef;
		/** Per-field validation errors forwarded to input nodes. */
		fieldErrors?: FieldErrorMap;
		/** Registrar for in-flight stage work (B-191), forwarded to input nodes. */
		registerFieldStage?: FieldStageRegistrar;
		/** Reference capsule click handler forwarded to children. */
		onreferenceclick?: ReferenceClickHandler;
		/** History-link href forwarded to nested `record-meta` nodes. */
		historyHref?: string;
	} = $props();

	const gridTemplate = $derived(parseGridLayout(template.layout));
	// A 2-column grid shares a single vertical divider between its cells
	// instead of an open gap. Mirrors the main/sidebar layout in
	// `frontend/example/facet_full_record_view_redesign.html`. Single-column
	// grids keep the default flow.
	const divided = $derived((template.children?.length ?? 0) === 2);
</script>

<div class="dvt-grid" class:divided style="grid-template-columns: {gridTemplate}" {...rest}>
	{#each template.children as child, ci (ci)}
		<div class="dvt-grid-cell">
			<DocumentViewTemplate
				template={child}
				{document}
				{values}
				{driver}
				{def}
				{fieldErrors}
				{registerFieldStage}
				{onreferenceclick}
				{historyHref}
			/>
		</div>
	{/each}
</div>

<style>
	.dvt-grid {
		display: grid;
		align-items: start;
		width: 100%;
	}

	/* When the grid has exactly two columns, the cells share a single
	   vertical divider rather than an open gap. The first cell carries the
	   border on its right edge. */
	.dvt-grid.divided {
		gap: 0;
	}

	.dvt-grid.divided .dvt-grid-cell {
		padding: 16px;
	}

	.dvt-grid.divided .dvt-grid-cell:first-child {
		border-right: 0.5px solid var(--border);
	}

	/* Fallback gap for grids that are not the 2-column divided layout. */
	.dvt-grid:not(.divided) {
		gap: 16px;
	}

	/* Collapse multi-column grids to single column when container is narrow. */
	@container (max-width: 359px) {
		.dvt-grid {
			grid-template-columns: 1fr !important;
			justify-items: center;
			gap: 12px;
		}

		.dvt-grid.divided .dvt-grid-cell {
			padding: 0;
			border-right: none;
		}

		.dvt-grid-cell {
			max-width: 100%;
			overflow: hidden;
		}
	}

	.dvt-grid-cell {
		min-width: 0;
	}
</style>
