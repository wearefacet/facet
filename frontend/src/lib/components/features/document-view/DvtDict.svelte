<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import DocumentViewTemplate from './DocumentViewTemplate.svelte';
	import { getDocContent, synthDoc, resolveRaw } from '$lib/template-resolve';
	import type { DictNode, ReferenceClickHandler } from '$lib/template-types';
	import type { DocumentResponse } from '$lib/datasource/types';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { DoctypeDef } from '$lib/doctype/types.js';

	let {
		template,
		document,
		values,
		driver,
		def,
		onreferenceclick,
		...rest
	}: {
		/** The dict iterator template node. */
		template: DictNode;
		/** The full document response. */
		document: DocumentResponse;
		values?: Record<string, unknown>;
		/** Driver forwarded to children for reference hydration. */
		driver?: DataDriver;
		/** Doctype definition forwarded to children. */
		def?: DoctypeDef;
		/** Reference capsule click handler forwarded to children. */
		onreferenceclick?: ReferenceClickHandler;
	} = $props();

	const content = $derived(getDocContent(document));
	const raw = $derived(resolveRaw(template.field, content));

	const entries = $derived.by(() => {
		if (raw == null || typeof raw !== 'object' || Array.isArray(raw)) return [];
		return Object.entries(raw as Record<string, unknown>).map(([key, value]) =>
			synthDoc({ key, value }, document)
		);
	});
</script>

{#if entries.length > 0}
	<div class="dvt-dict" {...rest}>
		{#each entries as entryDoc, i (i)}
			<div class="dvt-dict-entry">
				{#each template.children as child, ci (ci)}
					<DocumentViewTemplate
						template={child}
						document={entryDoc}
						{values}
						{driver}
						{def}
						{onreferenceclick}
					/>
				{/each}
			</div>
		{/each}
	</div>
{/if}

<style>
	.dvt-dict {
		display: flex;
		flex-direction: column;
		gap: 2px;
	}

	.dvt-dict-entry {
		display: flex;
		align-items: baseline;
		gap: 8px;
		padding: 4px 0;
		border-bottom: 1px solid var(--border);
	}

	.dvt-dict-entry:last-child {
		border-bottom: none;
	}
</style>
