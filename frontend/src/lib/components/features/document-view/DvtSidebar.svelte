<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import DocumentViewTemplate from './DocumentViewTemplate.svelte';
	import type { SidebarNode, ReferenceClickHandler } from '$lib/template-types';
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
		/** The sidebar template node. */
		template: SidebarNode;
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

<aside class="dvt-sidebar" {...rest}>
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
</aside>

<style>
	/* The sidebar holds sections (Owner, Tags, Record), not fields, so its
	   inter-section rhythm is the larger 18px from
	   `frontend/example/facet_full_record_view_redesign.html`. */
	.dvt-sidebar {
		display: flex;
		flex-direction: column;
		gap: 18px;
		min-width: 0;
	}
</style>
