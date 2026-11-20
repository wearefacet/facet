<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import Select from '$lib/components/primitives/forms/Select.svelte';
	import { getDocContent, fieldDefFor } from '$lib/template-resolve';
	import { joinFieldErrors } from '$lib/doctype/fieldErrors.js';
	import type { FieldErrorMap } from '$lib/doctype/fieldErrors.js';
	import type { InputSelectNode, ReferenceClickHandler } from '$lib/template-types';
	import type { DocumentResponse } from '$lib/datasource/types';
	import type { DoctypeDef } from '$lib/doctype/types.js';
	import Badge from '$lib/components/primitives/data/Badge.svelte';

	let {
		template,
		document,
		values,
		fieldErrors,
		def,
		onreferenceclick: _onreferenceclick,
		...rest
	}: {
		/** The input-select template node. */
		template: InputSelectNode;
		/** The full document response — initial values read from here. */
		document: DocumentResponse;
		values?: Record<string, unknown>;
		/** Per-field validation errors keyed by top-level segment (forwarded by the form page). */
		fieldErrors?: FieldErrorMap;
		/** Doctype definition — used to detect field type for view-mode rendering. */
		def?: DoctypeDef;
		/** Reference capsule click handler forwarded by parent. */
		onreferenceclick?: ReferenceClickHandler;
	} = $props();

	const content = $derived(getDocContent(document));
	const fieldTop = $derived(template.field.split('.', 1)[0] || template.field);
	const error = $derived(joinFieldErrors(fieldErrors, fieldTop));
	// Eagerly initialise so values[field] is never undefined at render time —
	// an $effect would run after the first render, by which point `bind:value`
	// has already rejected `undefined` (Select.value has a $bindable fallback).
	// Skipped in display context (no `values` bag) — input nodes require a
	// form owner.
	// svelte-ignore state_referenced_locally — intentional initial seeding:
	// the form owner (DocumentForm) seeds its bag once from the loaded
	// document; later content updates must not clobber user edits.
	if (values && values[template.field] === undefined) {
		values[template.field] = String(content[template.field] ?? '');
	}

	// ── Type-aware view rendering ─────────────────────────────────────────
	const fieldDef = $derived(fieldDefFor(def, template.field));
	const fieldType = $derived(fieldDef?.type ?? null);
	const fieldRawValue = $derived(content[template.field]);
	/** Convert snake_case enum values to human-readable labels. */
	function humanize(v: string): string {
		return v.replace(/_/g, ' ').replace(/\b\w/g, (c) => c.toUpperCase());
	}
	// When the field is an enum, resolve the label from the template's options
	// or the definition's values array.
	const enumLabel = $derived.by(() => {
		if (fieldType !== 'enum') return null;
		const raw = String(fieldRawValue ?? '');
		if (!raw) return null;
		// First try template-provided options (they have labels).
		const tplOpt = template.options.find((o) => o.value === raw);
		if (tplOpt) return tplOpt.label;
		// Fall back to humanized raw value.
		return humanize(raw);
	});
</script>

<div class="dvt-input-select" {...rest}>
	{#if values}
		<Select
			label={template.label}
			options={template.options}
			placeholder={template.placeholder}
			required={template.required}
			{error}
			bind:value={values[template.field] as string}
		/>
	{:else}
		<div class="dvt-input-select-readonly">
			<span class="dvt-input-select-label">{template.label}</span>
			{#if fieldType === 'enum'}
				<Badge label={enumLabel ?? String(fieldRawValue ?? '')} />
			{:else}
				<span class="dvt-input-select-value">{String(fieldRawValue ?? '')}</span>
			{/if}
		</div>
	{/if}
</div>

<style>
	.dvt-input-select {
		padding: 4px 0;
	}

	.dvt-input-select-readonly {
		display: flex;
		align-items: baseline;
		gap: 8px;
		padding: 6px 0;
		border-bottom: 1px solid var(--border);
	}

	.dvt-input-select-label {
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

	.dvt-input-select-value {
		font-size: 13px;
		color: var(--text);
	}
</style>
