<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import DocumentViewTemplate from './DocumentViewTemplate.svelte';
	import { getDocContent, synthDoc, resolveRaw, fieldDefFor } from '$lib/template-resolve';
	import type { ArrayNode, ReferenceClickHandler } from '$lib/template-types';
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
		/** The array iterator template node. */
		template: ArrayNode;
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

	// Display items — always derived for safety, used when values bag is absent.
	const displayItems = $derived(
		Array.isArray(raw)
			? (raw as unknown[]).map((item) =>
					synthDoc(
						typeof item === 'object' && item != null
							? (item as Record<string, unknown>)
							: { value: item },
						document
					)
				)
			: []
	);

	// Primitive items present — the inline layout only flows those; object
	// items render as cards in both layouts.
	const inlineCount = $derived(
		Array.isArray(raw)
			? (raw as unknown[]).filter((item) => typeof item !== 'object' || item == null).length
			: 0
	);

	// Form mode: initialise values[field] as a mutable copy of the array.
	// Each item object IS the sub-values bag for its children.
	$effect(() => {
		if (values && !(template.field in values)) {
			const arr = Array.isArray(raw) ? (raw as unknown[]) : [];
			values[template.field] = arr.map((item) => {
				if (typeof item === 'object' && item != null) {
					// Shallow copy so mutations don't leak back to document.data
					return { ...(item as Record<string, unknown>) };
				}
				return item;
			});
		}
	});

	/** Add an empty item to the form array. */
	function addItem() {
		if (!values) return;
		const arr = values[template.field];
		if (!Array.isArray(arr)) return;
		if (arr.length > 0 && typeof arr[0] !== 'object') {
			// Primitive array — push an empty string
			arr.push('' as never);
		} else {
			arr.push({} as never);
		}
	}

	// Children of object items resolve bare sub-field keys, so they need the
	// item schema's definitions: narrow the def to the array item's declared
	// `properties` (same narrowing as `DvtObject`). Scalar items keep the
	// root def — their children bind `$value`, not a defined field.
	const itemDef = $derived.by(() => {
		if (!def) return undefined;
		const fd = fieldDefFor(def, template.field);
		if (!fd || fd.type !== 'array') return def;
		const props = fd.items?.properties;
		if (!props || props.length === 0) return def;
		return { ...def, fields: props };
	});

	/** Remove an item from the form array by index. */
	function removeItem(index: number) {
		if (!values) return;
		const arr = values[template.field];
		if (!Array.isArray(arr)) return;
		arr.splice(index, 1);
	}
</script>

<div class="dvt-array" {...rest}>
	{#if values}
		<!-- ── FORM MODE (editable) ── -->
		{@const formArr = values[template.field] as unknown[]}
		{#if formArr && formArr.length > 0}
			{#each formArr as item, i (i)}
				{#if typeof item === 'object' && item != null}
					<!-- Object item — item IS the values bag -->
					{@const objItem = item as Record<string, unknown>}
					<div class="dvt-array-card">
						<div class="dvt-array-header">
							<span class="dvt-array-index">{i + 1}</span>
							<button
								class="dvt-array-remove"
								title={m.doc_array_remove_title()}
								onclick={() => removeItem(i)}>✕</button
							>
						</div>
						<div class="dvt-array-body">
							{#each template.children as child, ci (ci)}
								<DocumentViewTemplate
									template={child}
									document={synthDoc(objItem, document)}
									values={objItem}
									{driver}
									def={itemDef}
									{onreferenceclick}
								/>
							{/each}
						</div>
					</div>
				{:else}
					<!-- Primitive item — wrapped in { value } for $value resolution, no values bag -->
					<div class="dvt-array-card">
						<div class="dvt-array-header">
							<span class="dvt-array-index">{i + 1}</span>
							<button
								class="dvt-array-remove"
								title={m.doc_array_remove_title()}
								onclick={() => removeItem(i)}>✕</button
							>
						</div>
						<div class="dvt-array-body">
							{#each template.children as child, ci (ci)}
								<DocumentViewTemplate
									template={child}
									document={synthDoc({ value: item }, document)}
									{driver}
									def={itemDef}
									{onreferenceclick}
								/>
							{/each}
						</div>
					</div>
				{/if}
			{/each}
		{:else}
			<div class="dvt-array-empty">{m.doc_items_empty()}</div>
		{/if}
		<button class="dvt-array-add" onclick={addItem}>{m.doc_array_add()}</button>
	{:else if displayItems.length > 0 && template.children.length > 0}
		<!-- ── DISPLAY MODE (read-only) ── -->
		{#if template.layout === 'stack'}
			{#each displayItems as itemDoc, i (i)}
				{@const item = (raw as unknown[])?.[i]}
				{#if typeof item === 'object' && item != null}
					<div class="dvt-array-card">
						<div class="dvt-array-display-body">
							{#each template.children as child, ci (ci)}
								<DocumentViewTemplate
									template={child}
									document={itemDoc}
									{driver}
									def={itemDef}
									{onreferenceclick}
								/>
							{/each}
						</div>
					</div>
				{:else}
					<div class="dvt-array-primitive">
						{#each template.children as child, ci (ci)}
							<DocumentViewTemplate
								template={child}
								document={itemDoc}
								{driver}
								def={itemDef}
								{onreferenceclick}
							/>
						{/each}
					</div>
				{/if}
			{/each}
		{:else}
			<!-- Inline layout (default): primitive items flow in one wrapping
				     row; object items keep cards, a structure that cannot inline. -->
			{#if inlineCount > 0}
				<div class="dvt-array-inline">
					{#each displayItems as itemDoc, i (i)}
						{@const item = (raw as unknown[])?.[i]}
						{#if typeof item !== 'object' || item == null}
							{#each template.children as child, ci (ci)}
								<DocumentViewTemplate
									template={child}
									document={itemDoc}
									{driver}
									def={itemDef}
									{onreferenceclick}
								/>
							{/each}
						{/if}
					{/each}
				</div>
			{/if}
			{#each displayItems as itemDoc, i (i)}
				{@const item = (raw as unknown[])?.[i]}
				{#if typeof item === 'object' && item != null}
					<div class="dvt-array-card">
						<div class="dvt-array-display-body">
							{#each template.children as child, ci (ci)}
								<DocumentViewTemplate
									template={child}
									document={itemDoc}
									{driver}
									def={itemDef}
									{onreferenceclick}
								/>
							{/each}
						</div>
					</div>
				{/if}
			{/each}
		{/if}
	{/if}
</div>

<style>
	.dvt-array {
		display: flex;
		flex-direction: column;
		gap: 8px;
	}

	.dvt-array-card {
		border: 1px solid var(--border);
		border-radius: var(--r);
		overflow: hidden;
	}

	.dvt-array-header {
		display: flex;
		align-items: center;
		gap: 4px;
		padding: 3px 10px;
		background: var(--sunken);
		border-bottom: 1px solid var(--border);
	}

	.dvt-array-index {
		flex: 1;
		font-size: 10px;
		font-weight: 700;
		color: var(--text-3);
	}

	.dvt-array-remove {
		display: flex;
		align-items: center;
		justify-content: center;
		width: 18px;
		height: 18px;
		border: none;
		border-radius: var(--r-sm);
		background: transparent;
		color: var(--text-3);
		font-size: 11px;
		cursor: pointer;
		padding: 0;
		line-height: 1;
		transition:
			background 0.1s,
			color 0.1s;
	}

	.dvt-array-remove:hover {
		background: var(--danger-weak);
		color: var(--danger);
	}

	.dvt-array-body {
		padding: 4px 10px;
	}

	.dvt-array-display-body {
		padding: 8px 12px;
	}

	.dvt-array-primitive {
		padding: 6px 12px;
		border: 1px solid var(--border);
		border-radius: var(--r);
	}

	.dvt-array-inline {
		display: flex;
		flex-direction: row;
		flex-wrap: wrap;
		align-items: center;
		gap: 6px;
	}

	.dvt-array-empty {
		font-size: 12px;
		color: var(--text-3);
		font-style: italic;
		padding: 16px;
		text-align: center;
		border: 1px dashed var(--border);
		border-radius: var(--r);
	}

	.dvt-array-add {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		align-self: flex-start;
		font-family: var(--font-sans);
		font-size: 12px;
		font-weight: 500;
		color: var(--accent-ink);
		background: none;
		border: 1px dashed var(--border-strong);
		border-radius: var(--r);
		padding: 6px 14px;
		cursor: pointer;
		transition:
			background 0.1s,
			border-color 0.1s;
	}

	.dvt-array-add:hover {
		background: var(--accent-weak);
		border-color: var(--accent);
	}
</style>
