<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import {
		resolveInterpolated,
		getDocContent,
		resolveRaw,
		isReferenceField,
		fieldDefFor
	} from '$lib/template-resolve';
	import { fieldVisible } from '$lib/permissions.svelte';
	import type { FieldNode, ReferenceClickHandler } from '$lib/template-types';
	import DocumentViewTemplate from './DocumentViewTemplate.svelte';
	import Capsule from '$lib/components/primitives/data/Capsule.svelte';
	import DvtValue from './DvtValue.svelte';
	import type { DocumentResponse } from '$lib/datasource/types';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { DoctypeDef, FieldDef } from '$lib/doctype/types.js';

	let {
		template,
		document,
		values,
		driver,
		def,
		onreferenceclick,
		...rest
	}: {
		/** The field template node. */
		template: FieldNode;
		/** The full document response. */
		document: DocumentResponse;
		values?: Record<string, unknown>;
		/** Driver for reference hydration. When omitted, references render as raw ids. */
		driver?: DataDriver;
		/** Doctype definition — used to detect reference-typed fields. */
		def?: DoctypeDef;
		/** Reference capsule click handler forwarded to Capsule. */
		onreferenceclick?: ReferenceClickHandler;
	} = $props();

	const content = $derived(getDocContent(document));
	const display = $derived(resolveInterpolated(template.value, content));
	const hasChildren = $derived(template.children != null && template.children.length > 0);

	// When the field's single `$key` token resolves to a declared `reference`
	// field, render a hydrated Capsule instead of plaintext. The capsule fetches
	// the targeted document's display_name on its own; we only forward the raw
	// qualified id and the driver. The driver and the click handler also reach
	// `DvtValue`, so a collection reference (an array value) hydrates into one
	// capsule per stored token there.
	const referenceMatch = $derived(isReferenceField(template.value, def));
	const referenceValue = $derived(
		referenceMatch ? resolveRaw(referenceMatch.fieldKey, content) : undefined
	);
	const showReferenceCapsule = $derived(
		!!referenceMatch && typeof referenceValue === 'string' && referenceValue.length > 0
	);

	// ── Type-aware field rendering ────────────────────────────────────────
	// When the template value is a simple `$field` (no interpolation), we can
	// look up the field's declared type in the doctype definition and render
	// the appropriate display component. Interpolated strings and fields with
	// children bypass this dispatch and fall back to plain text.
	const isSimpleField = $derived(
		!hasChildren && !showReferenceCapsule && /^\$[A-Za-z_][A-Za-z0-9_]*$/.test(template.value)
	);
	const fieldDef = $derived.by<FieldDef | null>(() => {
		if (!isSimpleField) return null;
		return fieldDefFor(def, template.value);
	});
	const fieldType = $derived(fieldDef?.type ?? null);
	const fieldRawValue = $derived.by(() => {
		if (!fieldDef) return undefined;
		return resolveRaw(fieldDef.key, content);
	});

	// B-176 alignment with the fallback form: a field the active role cannot
	// see renders no row at all. The backend read mask omits the field's key
	// from `content`, so the row could only ever show the generic blank dash
	// — indistinguishable from a genuinely empty field. The check needs the
	// field definition, so it covers simple `$field` values only; interpolated
	// strings keep the plain rendering (the mask already blanked their
	// tokens). Same affordance filter the fallback form and the
	// DvtRelation fallback walk apply.
	const hiddenField = $derived.by<boolean>(() => {
		if (!/^\$[A-Za-z_][A-Za-z0-9_]*$/.test(template.value)) return false;
		const boundDef = fieldDefFor(def, template.value);
		return boundDef !== null && !fieldVisible(boundDef);
	});
</script>

{#if !hiddenField}
	<div class="dvt-field" class:unlabeled={!template.label} {...rest}>
		{#if template.label}
			<span class="dvt-field-label" title={template.label}>{template.label}</span>
		{/if}
		<span class="dvt-field-value">
			{#if hasChildren}
				{#each template.children! as child, ci (ci)}
					<DocumentViewTemplate
						template={child}
						{document}
						{values}
						{driver}
						{def}
						{onreferenceclick}
					/>
				{/each}
			{:else if showReferenceCapsule}
				<Capsule
					{driver}
					reference={referenceValue as string}
					qualifiedDoctype={referenceMatch!.qualifiedDoctype}
					{onreferenceclick}
				/>
			{:else}
				<DvtValue
					value={fieldRawValue}
					{fieldType}
					{fieldDef}
					fallback={display}
					{driver}
					{onreferenceclick}
				/>
			{/if}
		</span>
	</div>
{/if}

<style>
	/* The field is a single canonical row: a fixed-width label column and a
	   value column that takes the rest. Vertical rhythm between rows is owned
	   by the wrapping column / section grid, never by per-row borders or
	   paddings. Mirrors `frontend/example/facet_full_record_view_redesign.html`
	   and `facet_quickview_candidate_redesign.html`. */
	.dvt-field {
		display: grid;
		grid-template-columns: 108px minmax(0, 1fr);
		gap: 8px;
		align-items: baseline;
	}

	/* When the field has no label of its own (the surrounding `section` owns
	   the label), collapse to a single full-width value column. */
	.dvt-field.unlabeled {
		grid-template-columns: minmax(0, 1fr);
	}

	.dvt-field-label {
		font-size: 13px;
		font-weight: 500;
		color: var(--text-2);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.dvt-field-value {
		font-size: 13px;
		color: var(--text);
		min-width: 0;
	}
</style>
