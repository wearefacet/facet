<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import ColorInput from '$lib/components/primitives/forms/ColorInput.svelte';
	import ColorSwatch from '$lib/components/primitives/data/ColorSwatch.svelte';
	import { getDocContent, fieldDefFor } from '$lib/template-resolve';
	import type { FieldErrorMap } from '$lib/doctype/fieldErrors.js';
	import type { InputColorNode } from '$lib/template-types';
	import type { DocumentResponse } from '$lib/datasource/types';
	import type { DoctypeDef } from '$lib/doctype/types.js';

	let {
		template,
		document,
		values,
		fieldErrors: _fieldErrors,
		def,
		...rest
	}: {
		/** The input-color template node. */
		template: InputColorNode;
		/** The full document response — initial values read from here. */
		document: DocumentResponse;
		values?: Record<string, unknown>;
		/** Per-field validation errors keyed by top-level segment. */
		fieldErrors?: FieldErrorMap;
		/** Doctype definition — used to detect field type for view-mode rendering. */
		def?: DoctypeDef;
	} = $props();

	const content = $derived(getDocContent(document));
	// Eagerly initialise so values[field] is never undefined at render time.
	// svelte-ignore state_referenced_locally — intentional initial seeding:
	// the form owner (DocumentForm) seeds its bag once from the loaded
	// document; later content updates must not clobber user edits.
	if (values && values[template.field] === undefined) {
		values[template.field] = content[template.field] ?? '';
	}

	// ── Type-aware view rendering ─────────────────────────────────────────
	const fieldDef = $derived(fieldDefFor(def, template.field));
	const fieldType = $derived(fieldDef?.type ?? null);
	const fieldRawValue = $derived(content[template.field]);
</script>

<div class="dvt-input-color" {...rest}>
	{#if values}
		<ColorInput
			label={template.label}
			placeholder={template.placeholder}
			bind:value={values[template.field] as string}
		/>
	{:else}
		<div class="dvt-input-color-readonly">
			<span class="dvt-input-color-label">{template.label}</span>
			{#if fieldType === 'color'}
				<ColorSwatch value={String(fieldRawValue ?? '')} />
			{:else}
				<span class="dvt-input-color-value">{String(fieldRawValue ?? '—')}</span>
			{/if}
		</div>
	{/if}
</div>

<style>
	.dvt-input-color {
		padding: 4px 0;
	}

	.dvt-input-color-readonly {
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 6px 0;
		border-bottom: 1px solid var(--border);
	}

	.dvt-input-color-label {
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

	.dvt-input-color-value {
		font-family: var(--font-mono);
		font-size: 13px;
		color: var(--text);
	}
</style>
