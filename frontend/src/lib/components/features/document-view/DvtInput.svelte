<script lang="ts" module>
	// The specialized controls the auto node dispatches to, keyed by the
	// synthesized node's `type`. Falls back to the text input — the same
	// display-safety net as the dispatch itself. The unannotated map keeps
	// each entry's own component type; indexing with the node's `type` union
	// resolves to the matching component.
	const controlFor = {
		'input-text': DvtInputText,
		'input-select': DvtInputSelect,
		'input-toggle': DvtInputToggle,
		'input-datetime': DvtInputDatetime,
		'input-date': DvtInputDate,
		'input-period': DvtInputPeriod,
		'input-dateperiod': DvtInputDateperiod,
		'input-longtext': DvtInputLongtext,
		'input-reference': DvtInputReference,
		'input-money': DvtInputMoney,
		'input-color': DvtInputColor,
		'input-file': DvtInputFile,
		'input-secret': DvtInputSecret
	};
</script>

<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import DvtInputText from './DvtInputText.svelte';
	import DvtInputSelect from './DvtInputSelect.svelte';
	import DvtInputToggle from './DvtInputToggle.svelte';
	import DvtInputDatetime from './DvtInputDatetime.svelte';
	import DvtInputDate from './DvtInputDate.svelte';
	import DvtInputPeriod from './DvtInputPeriod.svelte';
	import DvtInputDateperiod from './DvtInputDateperiod.svelte';
	import DvtInputLongtext from './DvtInputLongtext.svelte';
	import DvtInputReference from './DvtInputReference.svelte';
	import DvtInputMoney from './DvtInputMoney.svelte';
	import DvtInputColor from './DvtInputColor.svelte';
	import DvtInputFile from './DvtInputFile.svelte';
	import DvtInputSecret from './DvtInputSecret.svelte';
	import { fieldDefFor } from '$lib/template-resolve';
	import { resolveAutoInput } from '$lib/doctype/autoInput.js';
	import type { InputAutoNode, ReferenceClickHandler } from '$lib/template-types';
	import type { DocumentResponse } from '$lib/datasource/types';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { DoctypeDef } from '$lib/doctype/types.js';
	import type { FieldErrorMap } from '$lib/doctype/fieldErrors.js';
	import type { FieldStageRegistrar } from './fieldStage.js';

	let {
		template,
		document,
		values,
		driver,
		def,
		fieldErrors,
		registerFieldStage,
		onreferenceclick,
		...rest
	}: {
		/** The auto input template node. */
		template: InputAutoNode;
		/** The full document response — initial values read from here. */
		document: DocumentResponse;
		/** Mutable form values bag. When absent (display context) the specialized component renders its read-only branch. */
		values?: Record<string, unknown>;
		/** Driver for reference hydration and search. */
		driver?: DataDriver;
		/** Doctype definition — the declared field type drives the dispatch. */
		def?: DoctypeDef;
		/** Per-field validation errors keyed by top-level segment (forwarded by the form page). */
		fieldErrors?: FieldErrorMap;
		/** Registrar for in-flight stage work (B-191), forwarded to the secret widget. */
		registerFieldStage?: FieldStageRegistrar;
		/** Reference capsule click handler forwarded by parent. */
		onreferenceclick?: ReferenceClickHandler;
	} = $props();

	// svelte-ignore state_referenced_locally — the bag is passed through as a
	// stable proxy: the form owner seeds it once and mutates it in place.
	const valuesState = $state(values);

	const fieldDef = $derived(fieldDefFor(def, template.field));
	const resolved = $derived(resolveAutoInput(fieldDef, template));

	const resolvedNode = $derived(resolved.kind === 'node' ? resolved.node : null);
	const Comp = $derived(
		resolvedNode ? (controlFor[resolvedNode.type] ?? DvtInputText) : DvtInputText
	);

	// The registrar only reaches the secret widget (B-191) — the one dispatch
	// target that stages out of band. The other targets never declare it, so
	// forwarding unconditionally would leak it through their `rest` spreads.
	const secretStageProps = $derived(
		resolvedNode?.type === 'input-secret' ? { registerFieldStage } : {}
	);

	// A replicated field is server-populated: the form must never edit it (the
	// backend rejects a write to it with a 422). Render its value read-only.
	const replicated = $derived(fieldDef?.replicate != null);

	const notEditableMessage = $derived.by(() => {
		if (resolved.kind !== 'not-editable') return null;
		switch (resolved.reason) {
			case 'array':
				return m.doc_input_auto_array({ field: template.field });
			case 'object':
				return m.doc_input_auto_object({ field: template.field });
			case 'dictionary':
				return m.doc_input_auto_dictionary({ field: template.field });
			case 'data':
				return m.doc_input_auto_computed({ field: template.field });
		}
	});
</script>

{#if replicated && values && resolvedNode}
	<div class="dvt-input-auto" {...rest}>
		<Comp
			template={resolvedNode as never}
			{document}
			{driver}
			{def}
			{fieldErrors}
			{onreferenceclick}
		/>
		<p class="dvt-input-auto-helper">{m.doc_input_auto_replicated()}</p>
	</div>
{:else if notEditableMessage}
	<div class="dvt-input-auto-error" {...rest} role="alert">
		{notEditableMessage}
	</div>
{:else}
	<div class="dvt-input-auto" {...rest}>
		<Comp
			template={resolvedNode as never}
			{document}
			values={valuesState as never}
			{driver}
			{def}
			{fieldErrors}
			{...secretStageProps}
			{onreferenceclick}
		/>
	</div>
{/if}

<style>
	.dvt-input-auto {
		display: block;
	}

	.dvt-input-auto-error {
		padding: 8px 12px;
		border: 1px dashed var(--border);
		border-radius: var(--r-sm);
		font-size: 12px;
		color: var(--text-2);
		background: var(--surface-2);
	}

	.dvt-input-auto-helper {
		margin: 4px 0 0;
		font-size: 11.5px;
		color: var(--text-3);
	}
</style>
