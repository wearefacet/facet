<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import PeriodPicker from '$lib/components/primitives/forms/PeriodPicker.svelte';
	import DvtValue from './DvtValue.svelte';
	import { getDocContent, fieldDefFor } from '$lib/template-resolve';
	import { joinFieldErrors } from '$lib/doctype/fieldErrors.js';
	import type { FieldErrorMap } from '$lib/doctype/fieldErrors.js';
	import type { InputPeriodNode } from '$lib/template-types';
	import type { DocumentResponse } from '$lib/datasource/types';
	import type { DoctypeDef, PeriodValue } from '$lib/doctype/types.js';

	let {
		template,
		document,
		values,
		fieldErrors,
		def
	}: {
		/** The input-period template node. */
		template: InputPeriodNode;
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
	// has already rejected `undefined` (PeriodPicker.value has a $bindable
	// fallback). A period field stores the composite `{start, end}` object;
	// '' clears.
	// svelte-ignore state_referenced_locally — intentional initial seeding:
	// the form owner (DocumentForm) seeds its bag once from the loaded
	// document; later content updates must not clobber user edits.
	if (values && values[template.field] === undefined) {
		const existing = content[template.field];
		values[template.field] =
			existing != null && typeof existing === 'object' ? (existing as PeriodValue) : '';
	}

	// ── Type-aware view rendering ─────────────────────────────────────────
	const fieldDef = $derived(fieldDefFor(def, template.field));
	const fieldType = $derived(fieldDef?.type ?? 'period');
	const fieldRawValue = $derived(content[template.field]);
</script>

<div class="dvt-input-period">
	{#if values}
		<PeriodPicker
			label={template.label}
			required={template.required}
			helper={template.helper}
			{error}
			mode="datetime"
			bind:value={values[template.field] as PeriodValue}
		/>
	{:else}
		<div class="dvt-input-period-readonly">
			<span class="dvt-input-period-label">{template.label}</span>
			<DvtValue value={fieldRawValue} {fieldType} {fieldDef} />
		</div>
	{/if}
</div>

<style>
	.dvt-input-period {
		padding: 4px 0;
	}

	.dvt-input-period-readonly {
		display: flex;
		align-items: baseline;
		gap: 8px;
		padding: 6px 0;
		border-bottom: 1px solid var(--border);
	}

	.dvt-input-period-label {
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
