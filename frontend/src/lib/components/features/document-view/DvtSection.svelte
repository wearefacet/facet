<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import DocumentViewTemplate from './DocumentViewTemplate.svelte';
	import type { SectionNode, ReferenceClickHandler } from '$lib/template-types';
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
		/** The section template node. */
		template: SectionNode;
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

<section class="dvt-section" {...rest}>
	<h3 class="dvt-section-label">{template.label}</h3>
	<div class="dvt-section-grid">
		{#each template.children as child, ci (ci)}
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
		{/each}
	</div>
</section>

<style>
	.dvt-section {
		display: block;
		min-width: 0;
	}

	/* Spacing between stacked sections: each section carries its own top
	   margin, zeroed for the first child so the stack starts flush. Sibling
	   selectors don't work across Svelte component boundaries, so the section
	   owns its own rhythm. 18px mirrors the section spacing in
	   `frontend/example/facet_full_record_view_redesign.html`. */
	.dvt-section:first-child {
		margin-top: 0;
	}

	.dvt-section:not(:first-child) {
		margin-top: 18px;
	}

	/* Eyebrow label — uppercase tracked mono caps, matches design-guideline
	   `.eyebrow` / `.grpttl` treatment. Sits above its field grid. */
	.dvt-section-label {
		margin: 0 0 10px;
		font-family: var(--font-mono);
		font-size: 11px;
		font-weight: 600;
		letter-spacing: 0.04em;
		text-transform: uppercase;
		color: var(--text-3);
	}

	/* Vertical rhythm between fields inside a section. The field row carries
	   no separator of its own; this gap is the single source of truth. */
	.dvt-section-grid {
		display: flex;
		flex-direction: column;
		gap: 9px;
		min-width: 0;
	}
</style>
