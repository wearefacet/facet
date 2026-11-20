<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import StringListEditor from '$lib/components/primitives/forms/StringListEditor.svelte';
	import { getDocContent } from '$lib/template-resolve';
	import { joinFieldErrors } from '$lib/doctype/fieldErrors.js';
	import type { FieldErrorMap } from '$lib/doctype/fieldErrors.js';
	import type { InputListNode, ReferenceClickHandler } from '$lib/template-types';
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
		/** The input-list template node. */
		template: InputListNode;
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
	// Display-mode list — derived straight from the document content so the
	// read-only branch never depends on the values bag. Non-string entries
	// (a malformed array field) fall back to their stringified form.
	const items = $derived.by<string[]>(() => {
		const stored = content[template.field];
		if (!Array.isArray(stored)) return [];
		return stored.map((v) => (typeof v === 'string' ? v : String(v)));
	});
	// Eagerly initialise so values[field] is a mutable string[] before the
	// first render — StringListEditor appends/splices that array in place.
	// The form seed's `''` cleared sentinel (array fields are seeded like
	// scalars for the fallback form's JSON editor) needs the same treatment
	// as an absent key. Skipped in display context (no `values` bag) — input
	// nodes require a form owner.
	// svelte-ignore state_referenced_locally — intentional initial seeding:
	// the form owner (DocumentForm) seeds its bag once from the loaded
	// document; later content updates must not clobber user edits.
	if (values && (values[template.field] === undefined || values[template.field] === '')) {
		const stored = content[template.field];
		values[template.field] = Array.isArray(stored)
			? stored.filter((v): v is string => typeof v === 'string')
			: [];
	}
</script>

<div class="dvt-input-list" {...rest}>
	{#if values}
		<!-- No bind: — StringListEditor only mutates the array in place
		     (push / pop / splice), so the shared reference keeps the form
		     bag in sync without a binding chain over a plain prop. -->
		<StringListEditor
			label={template.label}
			values={values[template.field] as string[]}
			placeholder={template.placeholder}
			helper={template.helper}
			{error}
		/>
	{:else}
		<div class="dvt-input-list-readonly">
			<span class="dvt-input-list-label">{template.label}</span>
			<span class="dvt-input-list-value" class:dvt-input-list-empty={items.length === 0}>
				{#each items as item, i (i)}
					<span class="dvt-input-list-chip">{item}</span>
				{/each}
				{#if items.length === 0}&mdash;{/if}
			</span>
		</div>
	{/if}
</div>

<style>
	.dvt-input-list {
		padding: 4px 0;
	}

	.dvt-input-list-readonly {
		display: flex;
		align-items: baseline;
		gap: 8px;
		padding: 6px 0;
		border-bottom: 1px solid var(--border);
	}

	.dvt-input-list-label {
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

	.dvt-input-list-value {
		display: flex;
		flex-wrap: wrap;
		gap: 5px;
		font-size: 13px;
		color: var(--text);
	}

	.dvt-input-list-chip {
		display: inline-flex;
		align-items: center;
		padding: 2px 8px;
		border-radius: 999px;
		font-family: var(--font-mono);
		font-size: 11.5px;
		color: var(--text-2);
		background: var(--surface-2);
		border: 1px solid var(--border-2);
	}

	.dvt-input-list-empty {
		color: var(--text-3);
	}
</style>
