<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import ReferencePicker from '$lib/components/primitives/forms/ReferencePicker.svelte';
	import Capsule from '$lib/components/primitives/data/Capsule.svelte';
	import { getDocContent, fieldDefFor } from '$lib/template-resolve';
	import { joinFieldErrors } from '$lib/doctype/fieldErrors.js';
	import type { FieldErrorMap } from '$lib/doctype/fieldErrors.js';
	import type { InputReferenceNode, ReferenceClickHandler } from '$lib/template-types';
	import type { DocumentResponse } from '$lib/datasource/types';
	import type { DoctypeDef } from '$lib/doctype/types.js';
	import type { DataDriver } from '$lib/datasource/driver.js';

	let {
		template,
		document,
		values,
		fieldErrors,
		def,
		driver,
		onreferenceclick,
		...rest
	}: {
		/** The input-reference template node. */
		template: InputReferenceNode;
		/** The full document response — initial values read from here. */
		document: DocumentResponse;
		values?: Record<string, unknown>;
		/** Per-field validation errors keyed by top-level segment. */
		fieldErrors?: FieldErrorMap;
		/** Doctype definition — used to detect the reference field's target doctype. */
		def?: DoctypeDef;
		/** Driver for reference hydration and search. */
		driver?: DataDriver;
		/** Reference capsule click handler forwarded by parent. */
		onreferenceclick?: ReferenceClickHandler;
	} = $props();

	const content = $derived(getDocContent(document));
	const fieldTop = $derived(template.field.split('.', 1)[0] || template.field);
	const error = $derived(joinFieldErrors(fieldErrors, fieldTop));

	// Seed the values bag from content when the form loads.
	// svelte-ignore state_referenced_locally — intentional initial seeding:
	// the form owner (DocumentForm) seeds its bag once from the loaded
	// document; later content updates must not clobber user edits.
	if (values && values[template.field] === undefined) {
		values[template.field] = content[template.field] ?? '';
	}

	// Resolve the target doctype from the field definition when the template
	// does not hardcode one. This lets the DVT author omit `doctype`/`doctypes`
	// when the field's type declaration already carries the reference target.
	// Reference fields may store the doctype qualified (`crm.Company`) or bare
	// (`Company`, same domain) — qualify bare names so the picker always gets
	// the canonical `{domain}.{Doctype}` form.
	const fieldDef = $derived(fieldDefFor(def, template.field));
	const targetDoctype = $derived(
		template.doctype ??
			(fieldDef?.doctype
				? fieldDef.doctype.includes('.')
					? fieldDef.doctype
					: `${def?.domain}.${fieldDef.doctype}`
				: undefined)
	);
	const targetDoctypes = $derived(
		template.doctypes ?? (targetDoctype ? [targetDoctype] : undefined)
	);
</script>

<div class="dvt-input-reference" {...rest}>
	{#if values}
		<ReferencePicker
			label={template.label}
			placeholder={template.placeholder}
			helper={template.helper}
			required={template.required}
			doctype={targetDoctype}
			doctypes={targetDoctypes}
			filter={fieldDef?.filter}
			driver={driver!}
			{error}
			bind:value={values[template.field] as string}
		/>
	{:else}
		<div class="dvt-input-reference-readonly">
			<span class="dvt-input-reference-label">{template.label}</span>
			{#if driver && content[template.field] && typeof content[template.field] === 'string' && String(content[template.field]).length > 0}
				<Capsule
					{driver}
					reference={String(content[template.field])}
					qualifiedDoctype={targetDoctype}
					{onreferenceclick}
				/>
			{:else}
				<span class="dvt-input-reference-value">{String(content[template.field] ?? '')}</span>
			{/if}
		</div>
	{/if}
</div>

<style>
	.dvt-input-reference {
		padding: 4px 0;
	}

	.dvt-input-reference-readonly {
		display: flex;
		align-items: baseline;
		gap: 8px;
		padding: 6px 0;
		border-bottom: 1px solid var(--border);
	}

	.dvt-input-reference-label {
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

	.dvt-input-reference-value {
		font-size: 13px;
		color: var(--text);
	}
</style>
