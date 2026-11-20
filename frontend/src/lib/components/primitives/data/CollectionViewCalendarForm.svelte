<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { DoctypeDef, FieldDef } from '$lib/doctype/types.js';
	import Select from '$lib/components/primitives/forms/Select.svelte';
	import Input from '$lib/components/primitives/forms/Input.svelte';
	import FilterBar from '$lib/components/primitives/navigation/FilterBar.svelte';
	import {
		colorByFields,
		discriminatorFields,
		dropUnknownFilter,
		endFields,
		fieldOptions
	} from '$lib/collectionView/config.js';

	/**
	 * Calendar-surface configuration form — discriminator, optional range
	 * end, chip colour, title template, and the embedded FilterBar. The
	 * calendar values live in the parent; each bindable prop round-trips the
	 * writes so the parent keeps its one-time-initialised draft state.
	 */
	let {
		doctype,
		driver,
		discriminator = $bindable(''),
		endField = $bindable(''),
		colorBy = $bindable(''),
		titleTemplate = $bindable(''),
		filterableFields,
		filters = $bindable<Record<string, unknown>>({}),
		discriminatorError = null,
		endFieldError = null,
		onDiscriminatorBlur,
		onEndFieldBlur
	}: {
		/** Parsed parent doctype definition (pickers and FilterBar read its fields). */
		doctype: DoctypeDef;
		/** Driver used by the FilterBar to resolve `reference` filters. */
		driver: DataDriver;
		/** Field key that anchors each document on the calendar grid. */
		discriminator?: string;
		/** Optional second date/datetime field forming a range. */
		endField?: string;
		/** Optional enum/reference field driving the chip colour. */
		colorBy?: string;
		/** Optional `{field}` title template. */
		titleTemplate?: string;
		/** Fields the FilterBar may filter on — stale keys drop against it. */
		filterableFields: FieldDef[];
		/** Active filters, keyed by `field__op`. */
		filters?: Record<string, unknown>;
		/** Set when the discriminator is required but empty, or the saved key
		 *  cannot serve the calendar's window filter any more. */
		discriminatorError?: string | null;
		/** Set when the saved end field cannot bound the range (no `gte`). */
		endFieldError?: string | null;
		/** Reports a blur of the date-field picker (reveals the required hint). */
		onDiscriminatorBlur?: () => void;
		/** Reports a blur of the end-field picker (reveals the capability hint). */
		onEndFieldBlur?: () => void;
	} = $props();

	const discriminatorOptions = $derived(fieldOptions(discriminatorFields(doctype.fields)));
	const showEndFields = $derived(endFields(doctype.fields, discriminator).length > 0);
	const endFieldOptions = $derived(fieldOptions(endFields(doctype.fields, discriminator)));
	const showColorByFields = $derived(colorByFields(doctype.fields, discriminator).length > 0);
	const colorByOptions = $derived(fieldOptions(colorByFields(doctype.fields, discriminator)));
</script>

<div class="cve-field">
	<Select
		label={m.list_editor_date_label()}
		placeholder={m.list_editor_date_placeholder()}
		options={discriminatorOptions}
		bind:value={discriminator}
		error={discriminatorError ?? undefined}
		onblur={() => onDiscriminatorBlur?.()}
		searchable={false}
	/>
	<span class="cve-field-helper">
		{m.list_editor_date_helper()}
	</span>
</div>

{#if showEndFields}
	<div class="cve-field">
		<Select
			label={m.list_editor_end_date_label()}
			placeholder={m.list_editor_end_date_placeholder()}
			options={endFieldOptions}
			bind:value={endField}
			error={endFieldError ?? undefined}
			onblur={() => onEndFieldBlur?.()}
			searchable={false}
		/>
		<span class="cve-field-helper"> {m.list_editor_end_date_helper()} </span>
	</div>
{/if}

{#if showColorByFields}
	<div class="cve-field">
		<Select
			label={m.list_editor_color_by_label()}
			placeholder={m.common_none()}
			options={colorByOptions}
			bind:value={colorBy}
			searchable={false}
		/>
		<span class="cve-field-helper"> {m.list_editor_color_helper()} </span>
	</div>
{/if}

<div class="cve-field">
	<Input
		label={m.list_editor_title_template_label()}
		placeholder={'e.g. {{ title }} {{ value }}'}
		bind:value={titleTemplate}
	/>
	<span class="cve-field-helper"> {m.list_editor_title_template_helper()} </span>
</div>

<div class="cve-field">
	<div class="cve-filters-head">
		<span class="cve-field-label">{m.list_editor_filters()}</span>
		<span class="cve-field-helper">{m.list_editor_filters_helper()}</span>
	</div>
	<FilterBar
		{doctype}
		{driver}
		{filters}
		onFilterChange={(next) => (filters = dropUnknownFilter(next, filterableFields))}
	/>
</div>

<style>
	.cve-field {
		display: flex;
		flex-direction: column;
		gap: 6px;
	}

	.cve-field-label {
		font-size: 12.5px;
		font-weight: 500;
		color: var(--text-2);
	}

	.cve-field-helper {
		font-size: 11.5px;
		color: var(--text-3);
	}

	.cve-filters-head {
		display: flex;
		align-items: baseline;
		justify-content: space-between;
		gap: 10px;
		flex-wrap: wrap;
	}
</style>
