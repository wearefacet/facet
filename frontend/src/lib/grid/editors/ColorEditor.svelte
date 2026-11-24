<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	The color editor — a hex input with a live swatch (the design mock's
	grid editor). The honeycomb picker stays a form-level affordance; in the
	cell, the entry is text: `#RGB` / `#RRGGBB`, normalized to uppercase
	`#RRGGBB` before the PATCH. A rejected commit marks the input and stays
	open. Enter commits down, Tab right, Escape cancels.
-->

<script lang="ts">
	import type { CellEditorProps, CommitMove } from './types.js';
	import { coerceScalar } from '../coerce.js';

	let { field, value, seed = null, label, ondraft, oncommit, oncancel }: CellEditorProps =
		$props();

	// svelte-ignore state_referenced_locally — seed-only: the editor mounts
	// fresh per open; the draft starts from the cell's value and the seed
	// char, then the input owns it.
	let draft = $state(seed ?? (value == null ? '' : String(value)));
	let error = $state<string | null>(null);

	const ariaLabel = $derived(label ?? field.title ?? field.key);
	/** The live swatch — the parsed colour, else transparent. */
	const swatch = $derived.by(() => {
		const result = coerceScalar(field, draft);
		return result.ok && typeof result.value === 'string' ? result.value : null;
	});

	function focusEnd(node: HTMLInputElement): void {
		node.focus();
		const n = node.value.length;
		node.setSelectionRange(n, n);
	}

	function publish(): void {
		const result = coerceScalar(field, draft);
		ondraft?.(result.ok ? result.value : draft, result.ok);
	}

	function commit(move: CommitMove): void {
		const result = coerceScalar(field, draft);
		if (!result.ok) {
			error = result.error;
			return;
		}
		oncommit(result.value, move);
	}

	function handleKeydown(e: KeyboardEvent): void {
		if (e.key === 'Enter') {
			e.preventDefault();
			commit('down');
		} else if (e.key === 'Tab') {
			e.preventDefault();
			commit(e.shiftKey ? null : 'right');
		} else if (e.key === 'Escape') {
			e.preventDefault();
			e.stopPropagation();
			oncancel();
		}
	}
</script>

<span class="color-swatch" style={swatch ? `background: ${swatch}` : 'background: transparent'} aria-hidden="true"></span>
<input
	use:focusEnd
	class="cell-input"
	type="text"
	bind:value={draft}
	aria-label={ariaLabel}
	placeholder="#RRGGBB"
	spellcheck="false"
	class:invalid={error != null}
	title={error ?? undefined}
	oninput={publish}
	onkeydown={handleKeydown}
/>

<style>
	.color-swatch {
		width: 14px;
		height: 14px;
		border-radius: 3px;
		border: 1px solid var(--border);
		flex-shrink: 0;
	}

	.cell-input {
		flex: 1;
		min-width: 0;
		height: 100%;
		border: none;
		background: none;
		font-family: var(--font-mono);
		font-size: 12.5px;
		color: var(--text);
		outline: none;
		padding: 0;
	}

	.cell-input:focus {
		outline: none;
	}

	.cell-input.invalid {
		color: var(--danger);
	}
</style>
