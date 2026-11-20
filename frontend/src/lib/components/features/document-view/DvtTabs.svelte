<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import Tabs from '$lib/components/primitives/navigation/Tabs.svelte';
	import TabPane from '$lib/components/primitives/navigation/TabPane.svelte';
	import Panel from '$lib/components/primitives/surfaces/Panel.svelte';
	import DocumentViewTemplate from './DocumentViewTemplate.svelte';
	import type { TabsNode, ReferenceClickHandler } from '$lib/template-types';
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
		/** The tabs template node. */
		template: TabsNode;
		/** The full document response — passed through to child template nodes. */
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

	const tabDefs = $derived(template.tabs.map((t) => ({ label: t.label })));

	let active = $state(0);

	function handleChange(index: number) {
		active = index;
	}
</script>

<div class="dvt-tabs" {...rest}>
	<Tabs tabs={tabDefs} bind:active onchange={handleChange} />
	<Panel>
		{#each template.tabs as tab, i (i)}
			<TabPane active={i === active}>
				{#each tab.children as child, ci (ci)}
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
			</TabPane>
		{/each}
	</Panel>
</div>

<style>
	.dvt-tabs {
		display: flex;
		flex-direction: column;
		gap: 10px;
	}
</style>
