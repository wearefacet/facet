<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import FieldValue from '$lib/components/primitives/data/FieldValue.svelte';
	import Capsule from '$lib/components/primitives/data/Capsule.svelte';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { ReferenceClickHandler } from '$lib/template-types';
	import type { FieldDef, FieldType } from '$lib/doctype/types.js';

	/**
	 * Render one typed field value for read-only display.
	 *
	 * A thin wrapper over the shared `FieldValue` primitive. It forwards the
	 * field type and the field definition, so every field type renders the
	 * same way on all document-view surfaces. Datetime values go through
	 * `RelativeTime`, the single relative-date component. Calendar dates
	 * (`date`) render verbatim. They are not instants. Range fields
	 * (`period` / `dateperiod`) render as `start → end`.
	 *
	 * A reference value hydrates through `Capsule` when the caller passes a
	 * `driver` — the capsule shows the target's `meta.display_name`, not the
	 * raw `domain.Type.id` token (B-132). Collection references hydrate too
	 * (F10-F): a JSON array of qualified ids renders one capsule per token,
	 * through the same `referenceCell` snippet the table passes to
	 * `FieldValue`. Callers without a driver keep the plain-text rendering;
	 * the reference value stays fully qualified in storage, so
	 * `fieldDef.doctype` is the qualified doctype hint Capsule needs for
	 * bare-id fallbacks.
	 */
	let {
		value,
		fieldType,
		fieldDef,
		fallback = '',
		driver,
		onreferenceclick
	}: {
		/** The raw field value from the document content. */
		value: unknown;
		/** The field's declared type. */
		fieldType: FieldType | null;
		/** The field definition — used for the money currency code. */
		fieldDef?: FieldDef | null;
		/** Plain-text fallback for untyped fields (e.g. interpolated values). */
		fallback?: string;
		/** Driver — when set, reference values (scalar or array) hydrate through `Capsule`. */
		driver?: DataDriver;
		/** Reference capsule click handler (requires `driver`). */
		onreferenceclick?: ReferenceClickHandler;
	} = $props();

	// Single-value references render through the dedicated Capsule branch
	// below. A `collection: true` reference stores a JSON array; it falls to
	// `FieldValue`, which calls the capsule snippet once per stored token.
	const referenceValue = $derived(
		fieldType === 'reference' && driver !== undefined && typeof value === 'string' && value !== ''
			? value
			: null
	);
</script>

<!-- Default reference cell, the table's pattern: one hydrated Capsule per
     stored token. Gated on the driver — without one, nothing can hydrate,
     and FieldValue keeps its plain-text rendering. -->
{#snippet capsuleCell(ref: string, refDef: FieldDef | null)}
	<Capsule {driver} reference={ref} qualifiedDoctype={refDef?.doctype} {onreferenceclick} />
{/snippet}

{#if referenceValue !== null}
	<Capsule
		{driver}
		reference={referenceValue}
		qualifiedDoctype={fieldDef?.doctype}
		{onreferenceclick}
	/>
{:else}
	<FieldValue
		{value}
		{fieldType}
		{fieldDef}
		{fallback}
		precision={fieldDef?.precision}
		referenceCell={driver ? capsuleCell : undefined}
	/>
{/if}
