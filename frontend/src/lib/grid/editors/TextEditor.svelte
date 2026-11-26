<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	The bare text editor — `string`, `phone`, `url`. One input that fills the
	cell: Enter commits and moves down, Tab commits and moves right, Escape
	cancels. An empty draft clears the field. The parse failure (none for
	these types today) would block the commit and mark the input invalid.
-->

<script lang="ts">
	import type { CellEditorProps, CommitMove } from './types.js';
	import { coerceScalar } from '../coerce.js';

	let { field, value, seed = null, label, ondraft, oncommit, oncancel }: CellEditorProps = $props();

	let inputEl = $state<HTMLInputElement | null>(null);
	// svelte-ignore state_referenced_locally — seed-only: the editor mounts
	// fresh per open; the draft starts from the cell's value and the seed
	// char, then the input owns it.
	let draft = $state(seed ?? (value == null ? '' : String(value)));
	let error = $state<string | null>(null);

	const ariaLabel = $derived(label ?? field.title ?? field.key);

	/** Focus the input once on mount, caret at the end. */
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

<input
	bind:this={inputEl}
	use:focusEnd
	class="cell-input"
	type="text"
	bind:value={draft}
	aria-label={ariaLabel}
	class:invalid={error != null}
	title={error ?? undefined}
	oninput={publish}
	onkeydown={handleKeydown}
/>

<style>
	.cell-input {
		flex: 1;
		min-width: 0;
		height: 100%;
		border: none;
		background: none;
		font-family: var(--font-sans);
		font-size: 13.5px;
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
