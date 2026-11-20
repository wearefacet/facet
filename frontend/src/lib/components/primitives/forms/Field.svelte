<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import type { Snippet } from 'svelte';

	/**
	 * Field — shared form-field chrome: label, required marker, helper and
	 * error text. One snippet renders the control body, so a form component
	 * keeps its own input and only owns control-specific CSS.
	 *
	 * The `children` snippet receives the `describedBy` id of the active
	 * helper/error text; the control puts it on `aria-describedby` so screen
	 * readers announce the right message. `error` wins over `helper` — the
	 * helper text is not rendered while an error is set.
	 *
	 * ```svelte
	 * <Field label="Amount" {helper} {error} id="amount" forId="amount-input">
	 * 	{#snippet children(meta)}
	 * 		<input id="amount-input" aria-describedby={meta.describedBy} />
	 * 	{/snippet}
	 * </Field>
	 * ```
	 */

	/** Ids the control needs to wire ARIA. */
	interface FieldMeta {
		/** `aria-describedby` target: the error id when `error` is set, else the helper id, else `undefined`. */
		describedBy: string | undefined;
	}

	let {
		label,
		required = false,
		helper,
		error,
		id,
		forId,
		labelId,
		labelClass,
		children
	}: {
		label?: string;
		required?: boolean;
		helper?: string;
		error?: string;
		/** Stable base id. The helper and error spans derive their ids from it. */
		id?: string;
		/** Id of the control the label points at (`for`). */
		forId?: string;
		/** Id for the label element itself — needed when a control uses `aria-labelledby`. */
		labelId?: string;
		/** One extra class for the label element — a stable hook for host styling. */
		labelClass?: string;
		/** The control body. Receives `{ describedBy }` for the `aria-describedby` wiring. */
		children: Snippet<[FieldMeta]>;
	} = $props();

	// The base id falls back to 'field' so a label-less control still gets
	// usable ids — same fallback the components used before this shared
	// chrome existed.
	const helperId = $derived(`${id ?? 'field'}-helper`);
	const errorId = $derived(`${id ?? 'field'}-err`);
	const describedBy = $derived(error ? errorId : helper ? helperId : undefined);
	const meta: FieldMeta = $derived({ describedBy });
</script>

{#if label}
	<label class="field-label {labelClass ?? ''}" id={labelId} for={forId}>
		{label}
		{#if required}
			<span class="field-required" aria-hidden="true">*</span>
		{/if}
	</label>
{/if}

{@render children(meta)}

{#if helper && !error}
	<span class="field-helper" id={helperId}>{helper}</span>
{/if}

{#if error}
	<span class="field-err" id={errorId} role="alert">{error}</span>
{/if}

<style>
	.field-label {
		font-size: 12.5px;
		font-weight: 500;
		color: var(--text-2);
	}

	.field-required {
		color: var(--danger);
		margin-left: 2px;
	}

	.field-helper {
		font-size: 11.5px;
		color: var(--text-3);
	}

	.field-err {
		font-size: 11.5px;
		color: var(--danger);
	}
</style>
