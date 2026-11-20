<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import { Plus, X } from '@lucide/svelte';
	import Field from './Field.svelte';

	/**
	 * StringListEditor — editable chips list for open-ended string arrays
	 * (e.g. `redirect_uris`, `allowed_origins`, `compatible_roles`).
	 *
	 * The `TagPicker` is a closed-option toggle and cannot accept free
	 * text; this component fills that gap. Each chip is removable; a
	 * text input at the end appends a new value on Enter or comma.
	 *
	 * The `values` prop is bindable so the parent `$state` array stays
	 * in sync. Mutations append/splice the array in place so derived
	 * values in the parent component re-render (per the workflow doc's
	 * deep-mutation rule — the parent's `$derived` of the same array
	 * recomputes when this component appends or removes an entry).
	 */

	let {
		values = $bindable([]),
		label,
		placeholder = m.doc_list_add_placeholder(),
		disabled = false,
		validator,
		helper,
		error
	}: {
		values?: string[];
		label?: string;
		placeholder?: string;
		disabled?: boolean;
		/** Returns an error string when the value is not acceptable; `null` means accept. */
		validator?: (value: string) => string | null;
		helper?: string;
		error?: string;
	} = $props();

	let draft = $state('');
	let draftError = $state<string | null>(null);

	const fieldId = $derived(label ? `sle-${label}` : undefined);
	const hasError = $derived(Boolean(error));

	function commit(): void {
		const v = draft.trim();
		if (!v) return;
		if (disabled) return;
		if (validator) {
			const msg = validator(v);
			if (msg) {
				draftError = msg;
				return;
			}
		}
		if (values.includes(v)) {
			draftError = m.doc_list_duplicate();
			return;
		}
		values.push(v);
		draft = '';
		draftError = null;
	}

	function onInput(e: Event): void {
		const target = e.target as HTMLInputElement;
		draft = target.value;
		// Clear the duplicate / validation error as soon as the user edits.
		draftError = null;
	}

	function onKeydown(e: KeyboardEvent): void {
		if (e.key === 'Enter' || e.key === ',') {
			e.preventDefault();
			commit();
		} else if (e.key === 'Backspace' && draft === '' && values.length > 0) {
			// Backspace on an empty input removes the last chip.
			values.pop();
		}
	}

	function remove(idx: number): void {
		values.splice(idx, 1);
	}
</script>

<div class="sle-wrap" id={fieldId} class:sle-error={hasError}>
	<Field
		{label}
		{helper}
		error={draftError ?? error}
		id={fieldId ?? undefined}
		forId={fieldId ?? undefined}
	>
		{#snippet children(meta)}
			<div class="sle-field" class:sle-disabled={disabled}>
				{#each values as value, i (value)}
					<span class="sle-chip">
						<span class="sle-chip-text">{value}</span>
						{#if !disabled}
							<button
								type="button"
								class="sle-chip-remove"
								aria-label={m.doc_list_remove_aria({ value })}
								onclick={() => remove(i)}
							>
								<X size={11} strokeWidth={2.2} aria-hidden="true" />
							</button>
						{/if}
					</span>
				{/each}
				<input
					type="text"
					class="sle-input"
					{placeholder}
					{disabled}
					value={draft}
					oninput={onInput}
					onkeydown={onKeydown}
					onblur={commit}
					aria-label={label ?? placeholder}
					aria-invalid={draftError || hasError ? 'true' : undefined}
					aria-describedby={meta.describedBy}
				/>
				<Plus
					size={14}
					strokeWidth={1.9}
					class="sle-add-icon"
					aria-hidden="true"
					onclick={commit}
				/>
			</div>
		{/snippet}
	</Field>
</div>

<style>
	.sle-wrap {
		display: flex;
		flex-direction: column;
		gap: 5px;
	}

	.sle-field {
		display: flex;
		flex-wrap: wrap;
		gap: 6px;
		align-items: center;
		padding: 6px 8px;
		min-height: 36px;
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface);
		transition:
			border-color 0.12s,
			box-shadow 0.12s;
	}

	.sle-field:focus-within {
		border-color: var(--accent);
		box-shadow: 0 0 0 3px var(--accent-weak);
	}

	.sle-disabled {
		opacity: 0.65;
		background: var(--surface-2);
	}

	.sle-chip {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		padding: 2px 4px 2px 8px;
		border-radius: var(--r-pill, 999px);
		font-family: var(--font-mono);
		font-size: 11.5px;
		color: var(--text);
		background: var(--surface-2);
		border: 1px solid var(--border-2);
		max-width: 32ch;
	}

	.sle-chip-text {
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
		min-width: 0;
		color: var(--text);
	}

	.sle-chip-remove {
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
	}

	.sle-chip-remove:hover {
		background: var(--surface);
		color: var(--danger);
	}

	.sle-input {
		flex: 1 1 12ch;
		min-width: 12ch;
		border: none;
		background: transparent;
		outline: none;
		font: inherit;
		font-size: 13px;
		color: var(--text);
		padding: 3px 0;
	}

	.sle-input::placeholder {
		color: var(--text-3);
	}

	:global(.sle-add-icon) {
		color: var(--text-3);
		cursor: pointer;
		flex: none;
	}

	:global(.sle-add-icon:hover) {
		color: var(--text);
	}

	/* Helper and error text render through the shared Field component.
	   The draft validation message wins over a prop error, same as the old
	   footer chain; Field gets it as the error. */

	.sle-error .sle-field {
		border-color: var(--danger);
	}
</style>
