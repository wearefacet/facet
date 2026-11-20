<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import DocumentViewTemplate from './DocumentViewTemplate.svelte';
	import { getDocContent, resolveRaw } from '$lib/template-resolve';
	import type { IfNode, ReferenceClickHandler } from '$lib/template-types';
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
		...rest
	}: {
		/** The conditional template node. */
		template: IfNode;
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
	} = $props();

	const content = $derived(getDocContent(document));
	const fieldValue = $derived(resolveRaw(template.field, content));

	const condition = $derived.by(() => {
		const val = fieldValue;
		if ('value' in template && template.value !== undefined) {
			return val === template.value;
		}
		return Boolean(val);
	});

	const nodes = $derived(condition ? template.children : (template.else ?? []));
</script>

{#if nodes.length > 0}
	<div class="dvt-if" class:dvt-if-true={condition} class:dvt-if-false={!condition} {...rest}>
		{#each nodes as child, ci (ci)}
			<DocumentViewTemplate
				template={child}
				{document}
				{values}
				{driver}
				{def}
				{fieldErrors}
				{registerFieldStage}
				{onreferenceclick}
			/>
		{/each}
	</div>
{/if}

<style>
	.dvt-if {
		display: contents;
	}
</style>
