<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import DatetimePicker from '$lib/components/primitives/forms/DatetimePicker.svelte';
	import DvtValue from './DvtValue.svelte';
	import { getDocContent, fieldDefFor } from '$lib/template-resolve';
	import { joinFieldErrors } from '$lib/doctype/fieldErrors.js';
	import type { FieldErrorMap } from '$lib/doctype/fieldErrors.js';
	import type { InputDateNode } from '$lib/template-types';
	import type { DocumentResponse } from '$lib/datasource/types';
	import type { DoctypeDef } from '$lib/doctype/types.js';

	let {
		template,
		document,
		values,
		fieldErrors,
		def
	}: {
		/** The input-date template node. */
		template: InputDateNode;
		/** The full document response — initial values read from here. */
		document: DocumentResponse;
		values?: Record<string, unknown>;
		/** Per-field validation errors keyed by top-level segment (forwarded by the form page). */
		fieldErrors?: FieldErrorMap;
		/** Doctype definition — used to detect field type for view-mode rendering. */
		def?: DoctypeDef;
	} = $props();

	const content = $derived(getDocContent(document));
	// Look up errors under the leading segment of `template.field` so nested
	// paths attribute to the top-level field.
	const fieldTop = $derived(template.field.split('.', 1)[0] || template.field);
	const error = $derived(joinFieldErrors(fieldErrors, fieldTop));
	// Eagerly initialise so values[field] is never undefined at render time —
	// an $effect would run after the first render, by which point `bind:value`
	// has already rejected `undefined` (DatetimePicker.value has a $bindable
	// fallback).
	// svelte-ignore state_referenced_locally — intentional initial seeding:
	// the form owner (DocumentForm) seeds its bag once from the loaded
	// document; later content updates must not clobber user edits.
	if (values && values[template.field] === undefined) {
		values[template.field] = content[template.field] ?? '';
	}

	// ── Type-aware view rendering ─────────────────────────────────────────
	const fieldDef = $derived(fieldDefFor(def, template.field));
	const fieldType = $derived(fieldDef?.type ?? 'date');
	const fieldRawValue = $derived(content[template.field]);
</script>

<div class="dvt-input-date">
	{#if values}
		<DatetimePicker
			label={template.label}
			required={template.required}
			helper={template.helper}
			{error}
			granularity="date"
			bind:value={values[template.field] as string}
		/>
	{:else}
		<div class="dvt-input-date-readonly">
			<span class="dvt-input-date-label">{template.label}</span>
			<DvtValue value={fieldRawValue} {fieldType} {fieldDef} />
		</div>
	{/if}
</div>

<style>
	.dvt-input-date {
		padding: 4px 0;
	}

	.dvt-input-date-readonly {
		display: flex;
		align-items: baseline;
		gap: 8px;
		padding: 6px 0;
		border-bottom: 1px solid var(--border);
	}

	.dvt-input-date-label {
		flex: 0 0 auto;
		min-width: 110px;
		max-width: 140px;
		font-size: 12.5px;
		font-weight: 500;
		color: var(--text-2);
		white-space: nowrap;
		overflow: hidden;
		text-overflow: ellipsis;
	}
</style>
