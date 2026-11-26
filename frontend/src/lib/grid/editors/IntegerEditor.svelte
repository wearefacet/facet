<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	The integer editor — a right-aligned numeric input with the declared
	`min` / `max` bounds as a left hint (the design mock's `0 – 100`). The
	bounds check runs before the PATCH is built; a rejected commit marks the
	input and stays open. Escape cancels; Enter commits down, Tab right.
-->

<script lang="ts">
	import type { CellEditorProps, CommitMove } from './types.js';
	import { coerceScalar } from '../coerce.js';

	let { field, value, seed = null, label, ondraft, oncommit, oncancel }: CellEditorProps = $props();

	// svelte-ignore state_referenced_locally — seed-only: the editor mounts
	// fresh per open; the draft starts from the cell's value and the seed
	// char, then the input owns it.
	let draft = $state(seed ?? (value == null ? '' : String(value)));
	let error = $state<string | null>(null);

	const ariaLabel = $derived(label ?? field.title ?? field.key);
	const boundsHint = $derived(
		field.min != null && field.max != null
			? `${field.min} – ${field.max}`
			: field.min != null
				? `≥ ${field.min}`
				: field.max != null
					? `≤ ${field.max}`
					: null
	);

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

{#if boundsHint != null}
	<span class="bounds-hint" aria-hidden="true">{boundsHint}</span>
{/if}
<input
	use:focusEnd
	class="cell-input"
	type="text"
	inputmode="numeric"
	bind:value={draft}
	aria-label={ariaLabel}
	class:invalid={error != null}
	title={error ?? undefined}
	oninput={publish}
	onkeydown={handleKeydown}
/>

<style>
	.bounds-hint {
		font-size: 11px;
		color: var(--text-3);
		font-family: var(--font-sans);
		white-space: nowrap;
		flex-shrink: 0;
	}

	.cell-input {
		flex: 1;
		min-width: 0;
		height: 100%;
		border: none;
		background: none;
		font-family: var(--font-mono);
		font-size: 13px;
		font-variant-numeric: tabular-nums;
		color: var(--text);
		outline: none;
		padding: 0;
		text-align: right;
	}

	.cell-input:focus {
		outline: none;
	}

	.cell-input.invalid {
		color: var(--danger);
	}
</style>
