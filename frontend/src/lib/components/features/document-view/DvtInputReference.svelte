<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import ReferencePicker from '$lib/components/primitives/forms/ReferencePicker.svelte';
	import ReferenceListEditor from '$lib/components/primitives/forms/ReferenceListEditor.svelte';
	import Capsule from '$lib/components/primitives/data/Capsule.svelte';
	import { referenceTokens } from '$lib/components/primitives/data/cellKind.js';
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

	// A `collection: true` reference stores a JSON array of qualified ids —
	// the list editor mutates the array in place; the single picker binds a
	// scalar through the shared bag.
	const isCollection = $derived(fieldDef?.type === 'reference' && fieldDef.collection === true);
	// One token per stored element for the read-only branch — a scalar wraps
	// into a one-element list, a collection splits per element (never a
	// comma-joined id string, which the capsule cannot resolve).
	const tokens = $derived(referenceTokens(content[template.field]));

	// Seed the values bag from content when the form loads.
	// svelte-ignore state_referenced_locally — intentional initial seeding:
	// the form owner (DocumentForm) seeds its bag once from the loaded
	// document; later content updates must not clobber user edits.
	if (values && values[template.field] === undefined) {
		const seeded = content[template.field];
		if (isCollection) {
			// A collection field must hold a real mutable array before the first
			// render — the list editor appends/splices it in place. The stored
			// array is cloned so the bag owns its value.
			values[template.field] = Array.isArray(seeded) ? [...seeded] : [];
		} else {
			values[template.field] = seeded ?? '';
		}
	} else if (values && isCollection && values[template.field] === '') {
		// The form seed's `''` cleared sentinel needs the same treatment as an
		// absent key (same rule as DvtInputList).
		values[template.field] = [];
	}
</script>

<div class="dvt-input-reference" {...rest}>
	{#if values}
		{#if isCollection}
			<!-- No bind: — ReferenceListEditor only mutates the array in place
			     (push / splice), so the shared reference keeps the form bag in
			     sync without a binding chain over a plain prop. -->
			<ReferenceListEditor
				label={template.label}
				placeholder={template.placeholder}
				helper={template.helper}
				required={template.required}
				doctype={targetDoctype}
				doctypes={targetDoctypes}
				filter={fieldDef?.filter}
				driver={driver!}
				{error}
				value={values[template.field] as string[]}
			/>
		{:else}
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
		{/if}
	{:else}
		<div class="dvt-input-reference-readonly">
			<span class="dvt-input-reference-label">{template.label}</span>
			{#if driver && tokens.length > 0}
				<span class="dvt-input-reference-tokens">
					{#each tokens as token (token)}
						<Capsule
							{driver}
							reference={token}
							qualifiedDoctype={targetDoctype}
							{onreferenceclick}
						/>
					{/each}
				</span>
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

	.dvt-input-reference-tokens {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 4px;
		min-width: 0;
	}
</style>
