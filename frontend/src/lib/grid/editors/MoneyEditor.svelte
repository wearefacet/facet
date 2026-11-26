<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	The money editor — mounts the platform's `MoneyInput` (currency chip +
	amount, locale-aware entry). The currency menu keeps its own keys: the
	wrapper only commits when the amount input holds a decimal or is empty,
	so an open menu or a currency typeahead never turns Enter into a commit.
	The emitted `{ value, currency }` passes through untouched; `''` commits
	the clear.
-->

<script lang="ts">
	import type { CellEditorProps, CommitMove } from './types.js';
	import MoneyInput from '$lib/components/primitives/forms/MoneyInput.svelte';
	import { DECIMAL_RE, SEP } from '$lib/components/primitives/forms/moneyFormat.js';

	let { field, value, label, ondraft, oncommit, oncancel }: CellEditorProps = $props();

	type MoneyValue = { value: string; currency: string } | '';

	// svelte-ignore state_referenced_locally — seed-only: the editor mounts
	// fresh per open; the binding seeds from the stored money object, then
	// MoneyInput owns it.
	let draft = $state<MoneyValue>(
		value != null && typeof value === 'object'
			? {
					value: String((value as Record<string, unknown>).value ?? ''),
					currency: String((value as Record<string, unknown>).currency ?? '')
				}
			: ''
	);

	const ariaLabel = $derived(label ?? field.title ?? field.key);

	function publish(): void {
		if (draft === '') {
			ondraft?.(null, true);
			return;
		}
		ondraft?.({ value: draft.value, currency: draft.currency }, true);
	}

	// The bindable `value` updates on every entry — publish each change.
	$effect(() => {
		void draft;
		publish();
	});

	/** Whether the amount input's text can commit — a decimal or a clear. */
	function amountCommittable(target: EventTarget | null): boolean {
		if (!(target instanceof HTMLInputElement)) return false;
		const raw = target.value.split(SEP).join('').trim();
		return raw === '' || DECIMAL_RE.test(raw);
	}

	function handleKeydown(e: KeyboardEvent): void {
		const target = e.target as HTMLElement;
		if (target.classList.contains('money-menu-filter')) return; // the menu's own keys
		if (e.key === 'Enter' || e.key === 'Tab') {
			if (!amountCommittable(e.target)) return; // currency typeahead — let it pick
			e.preventDefault();
			commit(e.key === 'Enter' ? 'down' : e.shiftKey ? null : 'right');
		} else if (e.key === 'Escape') {
			// MoneyInput's own Escape closes the menu/typeahead first and stops
			// propagation; this runs only when no menu is open.
			e.preventDefault();
			e.stopPropagation();
			oncancel();
		}
	}

	function commit(move: CommitMove): void {
		if (draft === '') {
			oncommit(null, move);
			return;
		}
		oncommit({ value: draft.value, currency: draft.currency }, move);
	}
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div class="money-editor" aria-label={ariaLabel} onkeydown={handleKeydown}>
	<MoneyInput bind:value={draft} preferredCurrency={field.currency} />
</div>

<style>
	.money-editor {
		flex: 1;
		min-width: 0;
		height: 100%;
		min-height: 0;
		display: flex;
		align-items: center;
	}

	/* The cell provides the frame — flatten the input's own box into it.
		   Every level carries an explicit height so the amount input spans the
		   frame: a percentage height against the box's content height resolves
		   short and parks the number at the top. */
	.money-editor :global(.money-input-wrap) {
		flex: 1;
		min-width: 0;
		height: 100%;
		min-height: 0;
	}

	.money-editor :global(.money-input-box) {
		border: none;
		background: none;
		padding: 0;
		height: 100%;
		min-height: 0;
		box-shadow: none;
	}

	.money-editor :global(.money-currency) {
		height: 100%;
		gap: 4px;
		padding: 0 7px;
	}

	.money-editor :global(.money-currency-symbol) {
		font-size: 12px;
	}

	.money-editor :global(.money-currency-code) {
		font-size: 11px;
	}

	.money-editor :global(.money-amount) {
		font-family: var(--font-mono);
		font-size: 13px;
		padding: 0;
		height: 100%;
		min-height: 0;
	}
</style>
