<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { X } from '@lucide/svelte';
	import Field from './Field.svelte';
	import ReferencePicker from './ReferencePicker.svelte';
	import Capsule from '../data/Capsule.svelte';
	import type { DataDriver } from '$lib/datasource/driver.js';

	/**
	 * ReferenceListEditor — editable chip list for multi-reference values.
	 *
	 * A `collection: true` reference field (and an `array` field whose
	 * `items` are `reference`) stores a JSON array of qualified ids —
	 * `{domain}.{Doctype}.{id}` tokens. This editor binds that array: each
	 * selected target renders as a hydrated `Capsule` chip with a remove
	 * button, and an embedded `ReferencePicker` acts as the add control —
	 * a pick appends the target instead of adopting it, so the user can
	 * add several in a row.
	 *
	 * The stored array is mutated in place (push / splice) so a bound
	 * `$state` bag in the parent re-renders (same contract as
	 * `StringListEditor`). A stored value that is not an array (the `''`
	 * cleared seed) is replaced with a one-element array on the first add.
	 * Picking a target already in the list shows the duplicate message —
	 * the backend rejects a repeated token with `duplicate_reference_target`.
	 */

	let {
		value = $bindable([]),
		label,
		placeholder,
		helper,
		required = false,
		disabled = false,
		error,
		doctype,
		doctypes,
		filter,
		driver
	}: {
		/** The bound token array (the field's stored shape). */
		value?: string[];
		label?: string;
		/** Placeholder for the embedded add picker. */
		placeholder?: string;
		helper?: string;
		required?: boolean;
		disabled?: boolean;
		error?: string;
		/** Forced mode: single qualified target doctype (e.g. `"crm.Company"`). */
		doctype?: string;
		/** Constrained mode: list of allowed qualified doctypes. */
		doctypes?: string[];
		/** Declarative `field__op: value` filter merged into the add picker's search. */
		filter?: Record<string, unknown>;
		/** Driver — chip label hydration and the add picker's record search. */
		driver: DataDriver;
	} = $props();

	const uid = Math.random().toString(36).slice(2, 10);
	const fieldId = $derived(label ? `rle-${label.replace(/\s+/g, '-')}-${uid}` : undefined);

	// A `''` cleared seed binds a non-array — render it as an empty list and
	// replace it on the first add (a reassignment the bound bag receives).
	const chips = $derived(Array.isArray(value) ? value : []);

	let dupError = $state<string | null>(null);
	const fieldError = $derived(error ?? dupError ?? undefined);

	/**
	 * Qualify a picked bare record id to its stored token form. The doctype
	 * the record was picked under is authoritative (a constrained/open
	 * picker lets the user choose it); the declared `doctype` prop is the
	 * fallback for a pick that somehow carries none.
	 */
	function qualify(id: string, pickedType: string | null): string {
		const dt = pickedType ?? doctype;
		if (!dt) return id;
		return id.startsWith(`${dt}.`) ? id : `${dt}.${id}`;
	}

	function add(pick: { id: string; label: string; doctype: string | null }): void {
		if (disabled) return;
		const token = qualify(pick.id, pick.doctype);
		if (!Array.isArray(value)) {
			value = [token];
		} else if (value.includes(token)) {
			dupError = m.doc_ref_duplicate();
			return;
		} else {
			value.push(token);
		}
		dupError = null;
	}

	function removeAt(index: number): void {
		if (disabled) return;
		if (!Array.isArray(value)) return;
		value.splice(index, 1);
		dupError = null;
	}
</script>

<div class="rle-wrap">
	<Field {label} {required} {helper} error={fieldError} id={fieldId ?? undefined}>
		{#snippet children(meta)}
			{#if chips.length > 0}
				<div class="rle-chips" aria-describedby={meta.describedBy}>
					{#each chips as token, i (token)}
						<span class="rle-chip">
							<Capsule {driver} reference={token} qualifiedDoctype={doctype} />
							{#if !disabled}
								<button
									type="button"
									class="rle-remove"
									aria-label={m.doc_list_remove_aria({ value: token })}
									onclick={() => removeAt(i)}
								>
									<X size={11} strokeWidth={2.2} aria-hidden="true" />
								</button>
							{/if}
						</span>
					{/each}
				</div>
			{/if}
			<ReferencePicker
				placeholder={placeholder ?? m.doc_ref_add_placeholder()}
				{driver}
				{doctype}
				{doctypes}
				{filter}
				{disabled}
				onpick={add}
			/>
		{/snippet}
	</Field>
</div>

<style>
	.rle-wrap {
		display: flex;
		flex-direction: column;
		gap: 5px;
	}

	.rle-chips {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 4px;
		padding-bottom: 2px;
	}

	.rle-chip {
		display: inline-flex;
		align-items: center;
		gap: 1px;
		max-width: 100%;
	}

	.rle-remove {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: 16px;
		height: 16px;
		border: none;
		border-radius: 50%;
		background: transparent;
		color: var(--text-3);
		cursor: pointer;
		flex: none;
		padding: 0;
	}

	.rle-remove:hover {
		background: var(--surface-2);
		color: var(--danger);
	}
</style>
