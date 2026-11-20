<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import Toggle from '$lib/components/primitives/forms/Toggle.svelte';
	import { getDocContent } from '$lib/template-resolve';
	import { joinFieldErrors } from '$lib/doctype/fieldErrors.js';
	import type { FieldErrorMap } from '$lib/doctype/fieldErrors.js';
	import type { InputToggleNode, ReferenceClickHandler } from '$lib/template-types';
	import type { DocumentResponse } from '$lib/datasource/types';
	import type { DoctypeDef } from '$lib/doctype/types.js';

	let {
		template,
		document,
		values,
		fieldErrors,
		def: _def,
		onreferenceclick: _onreferenceclick,
		...rest
	}: {
		/** The input-toggle template node. */
		template: InputToggleNode;
		/** The full document response — initial values read from here. */
		document: DocumentResponse;
		values?: Record<string, unknown>;
		/** Per-field validation errors keyed by top-level segment (forwarded by the form page). */
		fieldErrors?: FieldErrorMap;
		/** Doctype definition — for consistency with other input components. */
		def?: DoctypeDef;
		/** Reference capsule click handler forwarded by parent. */
		onreferenceclick?: ReferenceClickHandler;
	} = $props();

	const content = $derived(getDocContent(document));
	const fieldTop = $derived(template.field.split('.', 1)[0] || template.field);
	const error = $derived(joinFieldErrors(fieldErrors, fieldTop));
	// Eagerly initialise so values[field] is never undefined at render time —
	// an $effect would run after the first render, by which point `bind:checked`
	// has already rejected `undefined`.
	// Skipped in display context (no `values` bag) — input nodes require a
	// form owner.
	// svelte-ignore state_referenced_locally — intentional initial seeding:
	// the form owner (DocumentForm) seeds its bag once from the loaded
	// document; later content updates must not clobber user edits.
	if (values && values[template.field] === undefined) {
		values[template.field] =
			content[template.field] !== undefined ? Boolean(content[template.field]) : false;
	}
</script>

<div class="dvt-input-toggle" {...rest}>
	{#if values}
		<Toggle label={template.label} {error} bind:checked={values[template.field] as boolean} />
	{:else}
		<div class="dvt-input-toggle-readonly">
			<span class="dvt-input-toggle-label">{template.label}</span>
			<span
				class="dvt-input-toggle-value"
				class:dvt-input-toggle-value-true={content[template.field] === true}
			>
				{content[template.field] === true ? '✓ Yes' : '✕ No'}
			</span>
		</div>
	{/if}
</div>

<style>
	.dvt-input-toggle {
		padding: 4px 0;
	}

	.dvt-input-toggle-readonly {
		display: flex;
		align-items: baseline;
		gap: 8px;
		padding: 6px 0;
		border-bottom: 1px solid var(--border);
	}

	.dvt-input-toggle-label {
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

	.dvt-input-toggle-value {
		font-size: 13px;
		color: var(--danger);
		font-weight: 500;
	}

	.dvt-input-toggle-value-true {
		color: var(--ok);
	}
</style>
