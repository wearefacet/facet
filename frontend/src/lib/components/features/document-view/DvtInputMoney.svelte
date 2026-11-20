<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import MoneyInput from '$lib/components/primitives/forms/MoneyInput.svelte';
	import DvtValue from './DvtValue.svelte';
	import { getDocContent, fieldDefFor } from '$lib/template-resolve';
	import { joinFieldErrors } from '$lib/doctype/fieldErrors.js';
	import type { FieldErrorMap } from '$lib/doctype/fieldErrors.js';
	import type { InputMoneyNode } from '$lib/template-types';
	import type { DocumentResponse } from '$lib/datasource/types';
	import type { DoctypeDef } from '$lib/doctype/types.js';
	import type { MoneyValue } from '$lib/doctype/types.js';

	let {
		template,
		document,
		values,
		fieldErrors,
		def,
		...rest
	}: {
		/** The input-money template node. */
		template: InputMoneyNode;
		/** The full document response — initial values read from here. */
		document: DocumentResponse;
		values?: Record<string, unknown>;
		/** Per-field validation errors keyed by top-level segment (forwarded by the form page). */
		fieldErrors?: FieldErrorMap;
		/** Doctype definition — used to detect the declared default currency and display precision. */
		def?: DoctypeDef;
	} = $props();

	const content = $derived(getDocContent(document));
	const fieldTop = $derived(template.field.split('.', 1)[0] || template.field);
	const error = $derived(joinFieldErrors(fieldErrors, fieldTop));

	const fieldDef = $derived(fieldDefFor(def, template.field));
	const fieldType = $derived(fieldDef?.type ?? null);

	// Eagerly initialise so values[field] is never undefined at render time —
	// `MoneyInput` binds `value` which has a `$bindable('')` fallback, but
	// seeding up-front keeps the read path consistent with the other input nodes.
	// Money fields store the composite `{value, currency}` object; '' clears.
	// svelte-ignore state_referenced_locally — intentional initial seeding:
	// the form owner (DocumentForm) seeds its bag once from the loaded
	// document; later content updates must not clobber user edits.
	if (values && values[template.field] === undefined) {
		const existing = content[template.field];
		values[template.field] =
			existing != null && typeof existing === 'object' ? (existing as MoneyValue) : '';
	}

	const fieldRawValue = $derived(content[template.field]);
</script>

<div class="dvt-input-money" {...rest}>
	{#if values}
		<MoneyInput
			label={template.label}
			idScope={document.meta.id}
			placeholder={template.placeholder}
			helper={template.helper}
			required={template.required}
			preferredCurrency={fieldDef?.currency}
			{error}
			bind:value={values[template.field] as MoneyValue | ''}
		/>
	{:else}
		<div class="dvt-input-money-readonly">
			<span class="dvt-input-money-readonly-label">{template.label}</span>
			<DvtValue value={fieldRawValue} {fieldType} {fieldDef} />
		</div>
	{/if}
</div>

<style>
	.dvt-input-money {
		padding: 4px 0;
	}

	.dvt-input-money-readonly {
		display: flex;
		align-items: baseline;
		gap: 8px;
		padding: 6px 0;
		border-bottom: 1px solid var(--border);
	}

	.dvt-input-money-readonly-label {
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
