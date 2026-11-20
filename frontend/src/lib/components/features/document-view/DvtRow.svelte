<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import DocumentViewTemplate from './DocumentViewTemplate.svelte';
	import type { RowNode, ReferenceClickHandler } from '$lib/template-types';
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
		/** The row template node. */
		template: RowNode;
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
</script>

<div class="dvt-row" style="grid-template-columns: {template.layout}" {...rest}>
	{#each template.children as child, ci (ci)}
		<div class="dvt-row-cell">
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
	/* A row is a single-line inline grid: each child occupies one column,
	   typically a `label` (content-sized `auto`) or `capsule`, with at most
	   one `1fr` column absorbing the slack. Use `grid` for column-based
	   layouts (main + sidebar), not `row`. */
	.dvt-row {
		display: grid;
		align-items: baseline;
		gap: 10px;
		min-width: 0;
	}

	.dvt-row-cell {
		min-width: 0;
	}

	/* Collapse to a wrapped flex row when the container is too narrow to fit
	   the columns inline — mirrors the `grid` container fallback. */
	@container (max-width: 359px) {
		.dvt-row {
			display: flex;
			flex-wrap: wrap;
			gap: 6px 10px;
		}
	}
</style>
