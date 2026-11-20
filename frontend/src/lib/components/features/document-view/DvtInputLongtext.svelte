<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import { getDocContent } from '$lib/template-resolve';
	import { joinFieldErrors } from '$lib/doctype/fieldErrors.js';
	import type { FieldErrorMap } from '$lib/doctype/fieldErrors.js';
	import type { InputLongtextNode, ReferenceClickHandler } from '$lib/template-types';
	import type { DocumentResponse } from '$lib/datasource/types';
	import type { DoctypeDef } from '$lib/doctype/types.js';
	import type { ArtifactUploadResult } from '$lib/artifacts.js';
	import Markdown from '$lib/components/primitives/content/Markdown.svelte';

	let {
		template,
		document,
		values,
		fieldErrors,
		def,
		onreferenceclick,
		uploadFile,
		...rest
	}: {
		/** The input-longtext template node. */
		template: InputLongtextNode;
		/** The full document response — initial values read from here. */
		document: DocumentResponse;
		values?: Record<string, unknown>;
		/** Per-field validation errors keyed by top-level segment (forwarded by the form page). */
		fieldErrors?: FieldErrorMap;
		/** Doctype definition — for consistency with other input components. */
		def?: DoctypeDef;
		/** Reference-chip click handler — forwarded into the Markdown surface
		 *  in both branches; the editor gates it (edit mode selects instead). */
		onreferenceclick?: ReferenceClickHandler;
		/** Injectable uploader — receives a `File` and returns `{ id, filename }`.
		 *  Defaults to a `POST /Api/core/artifacts` call via `apiFetch`. Storybook
		 *  stories pass a synthetic uploader so the play function can assert the
		 *  artifact-link insertion without a live backend. */
		uploadFile?: (file: File) => Promise<ArtifactUploadResult>;
	} = $props();

	const content = $derived(getDocContent(document));
	const fieldTop = $derived(template.field.split('.', 1)[0] || template.field);
	const error = $derived(joinFieldErrors(fieldErrors, fieldTop));
	// Eagerly initialise so values[field] is never undefined at render time.
	// Skipped in display context (no `values` bag) — input nodes require a
	// form owner.
	// svelte-ignore state_referenced_locally — intentional initial seeding:
	// the form owner (DocumentForm) seeds its bag once from the loaded
	// document; later content updates must not clobber user edits.
	if (values && values[template.field] === undefined) {
		values[template.field] = String(content[template.field] ?? '');
	}

	const current = $derived(String(values?.[template.field] ?? content[template.field] ?? ''));
	// The editable surface is a composite (Milkdown / CodeMirror, not a
	// labelable control) — the label points at the field box, the same
	// pattern Field uses for composite controls.
	const fieldId = $props.id();
</script>

<div class="dvt-input-longtext" {...rest}>
	{#if values}
		{#if template.label}
			<label class="dvt-input-longtext-label" for={fieldId}>
				{template.label}
			</label>
		{/if}
		<!-- The Markdown primitive owns the editors (preview, WYSIWYG, source)
			and the expand overlay — this node adds the form glue: label, values
			bag writeback, field errors, and the field box. -->
		<div class="dvt-input-longtext-field" id={fieldId} class:dvt-input-longtext-field-err={error}>
			<Markdown
				mode="write"
				value={current}
				placeholder={template.placeholder}
				onchange={(v) => (values[template.field] = v)}
				{uploadFile}
				domain={def?.domain ?? ''}
				onReferenceClick={onreferenceclick}
			/>
		</div>
		{#if error}
			<span class="dvt-input-longtext-err" role="alert">{error}</span>
		{/if}
	{:else}
		{#if template.label}
			<span class="dvt-input-longtext-label">{template.label}</span>
		{/if}
		<div class="dvt-input-longtext-field">
			<Markdown value={current} readonly bare onReferenceClick={onreferenceclick} />
		</div>
	{/if}
</div>

<style>
	.dvt-input-longtext {
		display: flex;
		flex-direction: column;
		gap: 5px;
		padding: 4px 0;
	}

	.dvt-input-longtext-label {
		font-size: 12.5px;
		font-weight: 500;
		color: var(--text-2);
	}

	.dvt-input-longtext-err {
		font-size: 11.5px;
		color: var(--danger);
	}

	/* Field box — the embedded Markdown surface runs bare; this wrapper
	 * draws the field border and focus ring for both the editable and the
	 * readonly branch. */
	.dvt-input-longtext-field {
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface);
		transition:
			border-color 0.12s,
			box-shadow 0.12s;
	}

	.dvt-input-longtext-field:focus-within {
		border-color: var(--accent);
		box-shadow: 0 0 0 3px var(--accent-weak);
	}

	.dvt-input-longtext-field-err {
		border-color: var(--danger);
	}

	.dvt-input-longtext-field-err:focus-within {
		border-color: var(--danger);
		box-shadow: 0 0 0 3px var(--danger-weak);
	}
</style>
