<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import DvtLabel from './DvtLabel.svelte';
	import DvtField from './DvtField.svelte';
	import DvtTabs from './DvtTabs.svelte';
	import DvtObject from './DvtObject.svelte';
	import DvtIf from './DvtIf.svelte';
	import DvtArray from './DvtArray.svelte';
	import DvtDict from './DvtDict.svelte';
	import DvtGrid from './DvtGrid.svelte';
	import DvtCol from './DvtCol.svelte';
	import DvtImage from './DvtImage.svelte';
	import DvtImageArtifact from './DvtImageArtifact.svelte';
	import DvtMarkdown from './DvtMarkdown.svelte';
	import DvtLink from './DvtLink.svelte';
	import DvtEmail from './DvtEmail.svelte';
	import DvtTitle from './DvtTitle.svelte';
	import DvtCapsule from './DvtCapsule.svelte';
	import DvtHr from './DvtHr.svelte';
	import DvtInputText from './DvtInputText.svelte';
	import DvtInput from './DvtInput.svelte';
	import DvtInputDatetime from './DvtInputDatetime.svelte';
	import DvtInputPeriod from './DvtInputPeriod.svelte';
	import DvtInputDateperiod from './DvtInputDateperiod.svelte';
	import DvtInputDate from './DvtInputDate.svelte';
	import DvtInputSelect from './DvtInputSelect.svelte';
	import DvtInputToggle from './DvtInputToggle.svelte';
	import DvtInputLongtext from './DvtInputLongtext.svelte';
	import DvtInputReference from './DvtInputReference.svelte';
	import DvtInputMoney from './DvtInputMoney.svelte';
	import DvtInputColor from './DvtInputColor.svelte';
	import DvtInputFile from './DvtInputFile.svelte';
	import DvtInputSecret from './DvtInputSecret.svelte';
	import DvtInputList from './DvtInputList.svelte';
	import DvtRelation from './DvtRelation.svelte';
	import DvtHeader from './DvtHeader.svelte';
	import DvtSection from './DvtSection.svelte';
	import DvtSidebar from './DvtSidebar.svelte';
	import DvtRecordMeta from './DvtRecordMeta.svelte';
	import DvtRow from './DvtRow.svelte';
	import type { TemplateNode, ReferenceClickHandler } from '$lib/template-types';
	import type { DocumentResponse } from '$lib/datasource/types';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { DoctypeDef } from '$lib/doctype/types.js';
	import type { FieldErrorMap } from '$lib/doctype/fieldErrors.js';
	import type { FieldStageRegistrar } from './fieldStage.js';

	/**
	 * Registry mapping template type strings to their rendering components.
	 *
	 * Each component receives the full `template` node (narrowed to its
	 * specific type) and the `document` for field resolution.
	 *
	 * In Svelte 5 runes mode, components are dynamic by default — storing
	 * a component constructor and rendering it inline works without
	 * `<svelte:component>`.
	 */
	const registry: Record<
		string,
		| typeof DvtLabel
		| typeof DvtField
		| typeof DvtTabs
		| typeof DvtObject
		| typeof DvtIf
		| typeof DvtArray
		| typeof DvtDict
		| typeof DvtGrid
		| typeof DvtCol
		| typeof DvtImage
		| typeof DvtImageArtifact
		| typeof DvtMarkdown
		| typeof DvtLink
		| typeof DvtEmail
		| typeof DvtTitle
		| typeof DvtCapsule
		| typeof DvtHr
		| typeof DvtInputText
		| typeof DvtInput
		| typeof DvtInputDatetime
		| typeof DvtInputPeriod
		| typeof DvtInputDateperiod
		| typeof DvtInputDate
		| typeof DvtInputSelect
		| typeof DvtInputToggle
		| typeof DvtInputLongtext
		| typeof DvtInputReference
		| typeof DvtInputMoney
		| typeof DvtInputColor
		| typeof DvtInputFile
		| typeof DvtInputSecret
		| typeof DvtInputList
		| typeof DvtRelation
		| typeof DvtHeader
		| typeof DvtSection
		| typeof DvtSidebar
		| typeof DvtRecordMeta
		| typeof DvtRow
	> = {
		label: DvtLabel,
		field: DvtField,
		tabs: DvtTabs,
		object: DvtObject,
		if: DvtIf,
		array: DvtArray,
		dict: DvtDict,
		grid: DvtGrid,
		col: DvtCol,
		image: DvtImage,
		'image-artifact': DvtImageArtifact,
		markdown: DvtMarkdown,
		link: DvtLink,
		email: DvtEmail,
		title: DvtTitle,
		capsule: DvtCapsule,
		hr: DvtHr,
		'input-text': DvtInputText,
		input: DvtInput,
		'input-datetime': DvtInputDatetime,
		'input-period': DvtInputPeriod,
		'input-dateperiod': DvtInputDateperiod,
		'input-date': DvtInputDate,
		'input-select': DvtInputSelect,
		'input-toggle': DvtInputToggle,
		'input-longtext': DvtInputLongtext,
		'input-reference': DvtInputReference,
		'input-money': DvtInputMoney,
		'input-color': DvtInputColor,
		'input-file': DvtInputFile,
		'input-secret': DvtInputSecret,
		'input-list': DvtInputList,
		relation: DvtRelation,
		header: DvtHeader,
		section: DvtSection,
		sidebar: DvtSidebar,
		'record-meta': DvtRecordMeta,
		row: DvtRow
	};

	let {
		template,
		document,
		values,
		driver,
		def,
		fieldErrors,
		registerFieldStage,
		onreferenceclick,
		historyHref
	}: {
		/** The template node to render. */
		template: TemplateNode;
		/** The full document response (contains `data` for content, `meta` for system fields). */
		document: DocumentResponse;
		/**
		 * Mutable form values bag for editing. When present, input nodes
		 * bind to this object's fields instead of reading from document data.
		 */
		values?: Record<string, unknown>;
		/**
		 * Optional driver — enables reference hydration in `DvtField` nodes
		 * so reference-typed values render as display-name capsules instead
		 * of raw qualified ids.
		 */
		driver?: DataDriver;
		/**
		 * Doctype definition of the rendered document — used by `DvtField`
		 * to detect which `$field` tokens are reference-typed and should hydrate.
		 */
		def?: DoctypeDef;
		/**
		 * Per-top-level-field validation errors from a 422 response. When
		 * present, input nodes render an inline error for their `template.field`.
		 */
		fieldErrors?: FieldErrorMap;
		/**
		 * Registrar for in-flight stage work (B-191). Forwarded only to the two
		 * input node kinds that can host an async widget — the explicit
		 * `input-secret` node and the auto `input` node that can resolve to it.
		 * Other nodes are left alone: most spread unknown props onto DOM
		 * elements, so a blind pass would leak the function into an attribute.
		 */
		registerFieldStage?: FieldStageRegistrar;
		/**
		 * Optional click handler for hydrated reference capsules — forwarded
		 * down to `DvtField` (and through it to `Capsule`) so clicking a
		 * reference inside any `DocumentViewTemplate` switches the parent
		 * preview to the referenced document. Wired by `ListView`'s QuickView.
		 */
		onreferenceclick?: ReferenceClickHandler;
		/**
		 * Optional History-link href for `record-meta` nodes. Derived by the
		 * show route from `meta.domain` / `meta.doc_type` / `meta.id`. Forwarded
		 * only to `DvtRecordMeta`; other components ignore it.
		 */
		historyHref?: string;
	} = $props();

	// Pass `values` through verbatim: when omitted, input nodes and DvtArray's
	// form mode stay dormant (undefined). Synthesizing `{}` here would trick
	// DvtArray into rendering edit controls (✕ / + Add item) in display stories.
	// svelte-ignore state_referenced_locally — the bag is passed through as a
	// stable proxy: every form owner seeds it once and mutates it in place,
	// so the prop identity never changes for the lifetime of the form.
	const valuesState = $state(values);

	const Comp = $derived(template ? registry[template.type] : undefined);

	// The registrar reaches only the node kinds that can host an async widget
	// (B-191): the explicit `input-secret` node and the auto `input` node that
	// can resolve to one. A blind pass to every Comp would leak the function
	// into DOM attributes on components that spread unknown props.
	const stageRegistrarProps = $derived(
		template.type === 'input-secret' || template.type === 'input' ? { registerFieldStage } : {}
	);

	// Malformed-template guard: an `input-*` node whose `field` binding
	// cannot render — either missing entirely, or a dotted path. Every input
	// component reads `template.field` during derived initialisation (missing
	// → throw, blanking the page), and a dotted path binds a literal flat key
	// (`values["config.enabled"]`) that no input component can read or write
	// back into the nested object. Render a visible diagnostic instead of
	// dispatching. Templates are validated at authoring time by
	// `Doctype::ViewTemplate` (both cases are `:error` there); this guard
	// covers rows persisted before validation existed.
	const inputTemplateError = $derived.by(() => {
		// A missing `template` or `document` prop is the same render-contract
		// breach as a malformed node: render the diagnostic instead of letting a
		// child throw. The props are typed non-nullable, but a render torn down
		// mid-flush (the shared-page story tests) can read them as undefined for
		// one tick — a throw here corrupts the page for the retry, a diagnostic
		// fails only the one story.
		if (!template) return m.doc_template_missing();
		if (!document) return m.doc_document_missing();
		if (template.type !== 'input' && !template.type.startsWith('input-')) return null;
		const field = (template as unknown as Record<string, unknown>).field;
		if (typeof field !== 'string' || field.trim().length === 0) {
			return m.doc_template_no_field({ type: template.type });
		}
		if (field.includes('.')) {
			return m.doc_template_dotted_field({ type: template.type, field });
		}
		return null;
	});
</script>

{#if Comp && !inputTemplateError}
	<Comp
		template={template as never}
		{document}
		values={valuesState as never}
		{driver}
		{def}
		{fieldErrors}
		{...stageRegistrarProps}
		{onreferenceclick}
		historyHref={historyHref as never}
	/>
{:else if inputTemplateError}
	<div class="dvt-input-template-error" role="alert">
		{inputTemplateError}
	</div>
{/if}

<style>
	.dvt-input-template-error {
		padding: 8px 12px;
		border: 1px dashed var(--border);
		border-radius: var(--r-sm);
		font-size: 12px;
		color: var(--text-2);
		background: var(--surface-2);
	}
</style>
