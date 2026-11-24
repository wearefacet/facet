<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	The color editor — the platform's `ColorInput` flattened into the cell
	frame: the hex text entry, the live swatch, and the honeycomb picker
	(focusing the input opens it, exactly like the form). The entry is text:
	`#RRGGBB`, normalized to uppercase before the PATCH; the picker writes
	the same shape. ColorInput only publishes valid hex — invalid text snaps
	back to the last valid value on blur, so the wrapper commits the bound
	value, and an emptied input commits the clear. While the honeycomb is
	open, Escape belongs to it (close, then cancel on a second press).
	Enter commits down, Tab right.
-->

<script lang="ts">
	import type { CellEditorProps, CommitMove } from './types.js';
	import ColorInput from '$lib/components/primitives/forms/ColorInput.svelte';

	let { value, seed = null, ondraft, oncommit, oncancel }: CellEditorProps = $props();

	// svelte-ignore state_referenced_locally — seed-only: the editor mounts
	// fresh per open; the binding starts from the seed char or the stored
	// hex, then ColorInput owns it (it only publishes valid hex).
	let draft = $state(seed ?? (value == null ? '' : String(value)));
	// svelte-ignore state_referenced_locally — seed-only: reflects the raw
	// input at open time; the wrapper's oninput keeps it current afterwards.
	let rawEmpty = $state(value == null || value === '');

	/** Mount action — the hex input takes the focus (and opens the picker). */
	function focusInput(node: HTMLElement): void {
		node.querySelector<HTMLInputElement>('input.color-field')?.focus();
	}

	$effect(() => {
		const v = draft;
		ondraft?.(rawEmpty ? null : v, true);
	});

	/** Whether the honeycomb popover is open — its Escape closes it first.
	 *  The popover renders through a portal on `body`, outside this tree. */
	function popoverOpen(): boolean {
		return document.querySelector('.color-popover') != null;
	}

	function commit(move: CommitMove): void {
		oncommit(rawEmpty ? null : draft, move);
	}

	function handleKeydown(e: KeyboardEvent): void {
		if (e.key === 'Enter') {
			e.preventDefault();
			commit('down');
		} else if (e.key === 'Tab') {
			e.preventDefault();
			commit(e.shiftKey ? null : 'right');
		} else if (e.key === 'Escape') {
			if (popoverOpen()) return; // the picker closes its popover first
			e.preventDefault();
			e.stopPropagation();
			oncancel();
		}
	}
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<!-- The wrapper's oninput watches the raw text for the clear rule; the
     honeycomb's own events render through the portal, never here. -->
<div
	class="color-editor"
	use:focusInput
	onkeydown={handleKeydown}
	oninput={(e) => (rawEmpty = (e.target as HTMLInputElement).value.trim() === '')}
>
	<ColorInput bind:value={draft} />
</div>

<style>
	.color-editor {
		flex: 1;
		min-width: 0;
		height: 100%;
		min-height: 0;
		display: flex;
		align-items: center;
	}

	/* The cell provides the frame — flatten the input's own box into it.
	   Explicit heights at every level keep the hex text vertically centred. */
	.color-editor :global(.color-input-wrap) {
		flex: 1;
		min-width: 0;
		height: 100%;
		min-height: 0;
	}

	.color-editor :global(.color-trigger) {
		flex: 1;
		height: 100%;
		min-height: 0;
	}

	.color-editor :global(.color-field) {
		flex: 1;
		min-width: 0;
		height: 100%;
		min-height: 0;
		border: none;
		background: none;
		font-family: var(--font-mono);
		font-size: 12.5px;
		color: var(--text);
		padding: 0 24px 0 0;
	}

	.color-editor :global(.color-trigger:focus-within .color-field) {
		border: none;
		box-shadow: none;
	}

	.color-editor :global(.color-swatch-button) {
		right: 2px;
	}

	.color-editor :global(.color-swatch) {
		width: 14px;
		height: 14px;
	}
</style>
