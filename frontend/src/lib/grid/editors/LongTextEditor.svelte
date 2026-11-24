<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	The longtext editor — a floating textarea over the cell. Enter inserts a
	new line; ⌘↵ / Ctrl↵ commits and moves down. Tab commits and moves
	right; Escape cancels. The floating frame (the shell's `.floating`) gives
	the text room over the rows below.
-->

<script lang="ts">
	import type { CellEditorProps, CommitMove } from './types.js';
	import { coerceScalar } from '../coerce.js';

	let { field, value, seed = null, label, ondraft, oncommit, oncancel }: CellEditorProps =
		$props();

	// svelte-ignore state_referenced_locally — seed-only: the editor mounts
	// fresh per open; the draft starts from the cell's value and the seed
	// char, then the textarea owns it.
	let draft = $state(seed ?? (value == null ? '' : String(value)));
	let error = $state<string | null>(null);

	const ariaLabel = $derived(label ?? field.title ?? field.key);

	function focusEnd(node: HTMLTextAreaElement): void {
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
		if (e.key === 'Enter' && (e.metaKey || e.ctrlKey)) {
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
		// A bare Enter stays untouched — it inserts the new line.
	}
</script>

<textarea
	use:focusEnd
	class="cell-textarea"
	bind:value={draft}
	aria-label={ariaLabel}
	class:invalid={error != null}
	title={error ?? undefined}
	oninput={publish}
	onkeydown={handleKeydown}
></textarea>

<style>
	.cell-textarea {
		flex: 1;
		min-width: 0;
		min-height: 72px;
		border: none;
		background: none;
		font-family: var(--font-sans);
		font-size: 13px;
		line-height: 1.45;
		color: var(--text);
		outline: none;
		padding: 0;
		resize: none;
	}

	.cell-textarea:focus {
		outline: none;
	}

	.cell-textarea.invalid {
		color: var(--danger);
	}
</style>
