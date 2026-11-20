<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import Input from '$lib/components/primitives/forms/Input.svelte';
	import { getDocContent, fieldDefFor } from '$lib/template-resolve';
	import { joinFieldErrors } from '$lib/doctype/fieldErrors.js';
	import type { FieldErrorMap } from '$lib/doctype/fieldErrors.js';
	import type { InputTextNode, ReferenceClickHandler } from '$lib/template-types';
	import type { DocumentResponse } from '$lib/datasource/types';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { DoctypeDef } from '$lib/doctype/types.js';
	import {
		ensureAbsoluteUrl,
		hasUrlScheme,
		urlAdornment,
		urlFieldError
	} from '$lib/doctype/urlValue.js';
	import DvtValue from './DvtValue.svelte';

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
		/** The input-text template node. */
		template: InputTextNode;
		/** The full document response — initial values read from here. */
		document: DocumentResponse;
		values?: Record<string, unknown>;
		/** Per-field validation errors keyed by top-level segment (forwarded by the form page). */
		fieldErrors?: FieldErrorMap;
		/** Doctype definition — used to detect field type for view-mode rendering. */
		def?: DoctypeDef;
		/** Driver for reference hydration. */
		driver?: DataDriver;
		/** Reference capsule click handler forwarded by parent. */
		onreferenceclick?: ReferenceClickHandler;
	} = $props();

	const content = $derived(getDocContent(document));
	const inputType = $derived(template.inputType ?? 'text');
	// Look up errors under the leading segment of `template.field` so nested
	// paths (`period.start`) attribute to the top-level field (`period`).
	const fieldTop = $derived(template.field.split('.', 1)[0] || template.field);
	// Eagerly initialise so values[field] is never undefined at render time —
	// an $effect would run after the first render, by which point `bind:value`
	// has already rejected `undefined` (Input.value has a $bindable fallback).
	// Skipped when no `values` bag was provided (display context) — input
	// nodes require a form owner to pass `values`.
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

	// Url fields complete dotted bare hosts and refuse everything else
	// (B-294): the backend's `UrlType#normalize` applies the same rule at
	// every entry point, and the form mirrors it so the field shows what
	// will be stored. On change (blur — typing must not be rewritten
	// mid-stroke) the bound value is normalized; `formDiff` re-applies the
	// same rule to the payload as a safety net.
	const fieldIsUrl = $derived(fieldType ? fieldType === 'url' : inputType === 'url');
	const urlScheme = $derived(
		template.prefix && hasUrlScheme(template.prefix) ? template.prefix : 'https://'
	);

	// A `prefix` is chrome, not data. A url field always implies a scheme —
	// the declared scheme-prefix or the `https://` default — and
	// `urlAdornment` shows it whenever the bound value carries no scheme, so
	// the user sees the form that will be stored instead of a silent blur
	// rewrite. Once the value self-describes (carries any scheme — a
	// hand-typed `http://` included), the chrome would only duplicate it and
	// drops out. Non-url fields keep the declared-prefix rule: chrome shows
	// for empty and scheme-less values that do not already start with it.
	const effectivePrefix = $derived.by(() => {
		if (fieldIsUrl) {
			const v = values?.[template.field];
			return urlAdornment(typeof v === 'string' ? v : undefined, urlScheme);
		}
		const p = template.prefix;
		if (!p) return undefined;
		const v = values?.[template.field];
		if (typeof v !== 'string' || v === '') return p;
		return v.startsWith(p) || hasUrlScheme(v) ? undefined : p;
	});

	// B-174/B-294: completing garbage must not read as committed data. A
	// value that fails the backend's `UrlType` gate after normalization (a
	// dotless host the backend would not complete, a malformed authority)
	// keeps the user's raw text and marks the field invalid instead of
	// swapping in the mangled string. Saving still reaches the backend —
	// the 422 field error lands in the same slot; this is the early,
	// non-silent half of the gate.
	let urlCommitError = $state<string | null>(null);
	const error = $derived(urlCommitError ?? joinFieldErrors(fieldErrors, fieldTop));

	function commitUrlValue(): void {
		if (!fieldIsUrl || !values) return;
		const v = values[template.field];
		if (typeof v !== 'string') return;
		urlCommitError = null;
		// The completed form is what the payload coercion sends, so the field
		// shows exactly what will be stored. Completion is restricted to the
		// dotted bare-host rule the backend applies; anything else passes
		// through for the gate to refuse.
		const fixed = ensureAbsoluteUrl(v, urlScheme);
		const invalid = urlFieldError(fixed);
		if (invalid !== null) {
			urlCommitError = invalid;
			return;
		}
		if (fixed !== v) values[template.field] = fixed;
	}
</script>

<div class="dvt-input-text" {...rest}>
	{#if values}
		<!-- `document.meta.id` is the row's draft id on inline child rows
		     (rowDocument), so the synthesized input id stays unique per row —
		     the StructuredInput `rf-{draft.id}-{field.key}` pattern (B-394). -->
		<Input
			type={inputType}
			label={template.label}
			idScope={document.meta.id}
			placeholder={template.placeholder}
			required={template.required}
			helper={template.helper}
			prefix={effectivePrefix}
			{error}
			oninput={() => (urlCommitError = null)}
			onchange={commitUrlValue}
			bind:value={values[template.field] as string}
		/>
	{:else}
		<div class="dvt-input-text-readonly">
			<span class="dvt-input-text-label">{template.label}</span>
			<DvtValue value={fieldRawValue} {fieldType} {fieldDef} {driver} {onreferenceclick} />
		</div>
	{/if}
</div>

<style>
	.dvt-input-text {
		padding: 4px 0;
	}

	.dvt-input-text-readonly {
		display: flex;
		align-items: baseline;
		gap: 8px;
		padding: 6px 0;
		border-bottom: 1px solid var(--border);
	}

	.dvt-input-text-label {
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
