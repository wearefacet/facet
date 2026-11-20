<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import DocumentViewTemplate from './DocumentViewTemplate.svelte';
	import { getDocContent, synthDoc, resolveRaw, fieldDefFor } from '$lib/template-resolve';
	import type { ObjectNode, ReferenceClickHandler } from '$lib/template-types';
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
		/** The object wrapper template node. */
		template: ObjectNode;
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
	const fieldValue = $derived(resolveRaw(template.field, content));
	// Children resolve bare sub-field keys, so they also need the sub-field
	// definitions: narrow the def to the bound object field's declared
	// `properties`. Without this, type-aware children (auto `input` dispatch,
	// typed read-only rows) would look up sub-field keys against the root
	// fields and fall back to untyped rendering.
	const childDef = $derived.by(() => {
		if (!def) return undefined;
		const fd = fieldDefFor(def, template.field);
		if (!fd || !fd.properties || fd.properties.length === 0) return def;
		return { ...def, fields: fd.properties };
	});
	// In form mode we render the section even when the stored value is null
	// (e.g. an empty `emergency` contact) so the user can populate it; the
	// empty-object fallback gives children a resolution root.
	const innerDoc = $derived(
		typeof fieldValue === 'object' && fieldValue != null
			? synthDoc(fieldValue as Record<string, unknown>, document)
			: values
				? synthDoc({}, document)
				: null
	);

	// Form mode: scope the values bag to this object's field. Without this,
	// children input nodes would bind to the PARENT values bag under the
	// inner field's name, colliding with sibling fields and never writing
	// back into the nested object. Mirrors DvtArray's per-item values bag.
	//
	// Eagerly initialise (synchronously, not in $effect) so the scoped values
	// bag exists before the first render. Otherwise children (DvtInputText,
	// DvtInputSelect) receive undefined and render in read-only mode.
	// This mirrors the same pattern used by DvtInputText and DvtInputSelect.
	// svelte-ignore state_referenced_locally — intentional initial seeding:
	// the form owner (DocumentForm) seeds its bag once from the loaded
	// document; later content updates must not clobber user edits.
	if (values && !(template.field in values)) {
		const seed =
			typeof fieldValue === 'object' && fieldValue != null
				? { ...(fieldValue as Record<string, unknown>) }
				: {};
		values[template.field] = seed;
	}
	const innerValues = $derived.by<Record<string, unknown> | undefined>(() => {
		if (!values) return undefined;
		const cur = values[template.field];
		return typeof cur === 'object' && cur != null ? (cur as Record<string, unknown>) : undefined;
	});
</script>

{#if innerDoc}
	<!-- `object` is a pure scope-shifter: it rebinds `$field` resolution for
	     its children to the nested object. It renders no header of its own —
	     wrap it in a `section` node when a label is wanted. -->
	<div class="dvt-object" {...rest}>
		{#each template.children as child, ci (ci)}
			<DocumentViewTemplate
				template={child}
				document={innerDoc}
				values={innerValues}
				{driver}
				def={childDef}
				{onreferenceclick}
			/>
		{/each}
	</div>
{/if}

<style>
	.dvt-object {
		display: block;
		min-width: 0;
	}
</style>
