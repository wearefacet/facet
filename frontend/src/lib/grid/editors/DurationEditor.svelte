<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	The duration editor — a right-aligned free-text input parsed through the
	platform's `durationMath.parseDuration` (`2h 30m`, `90`, `26:30:00`). The
	parsed total renders as a live hint; the declared `min` / `max` (seconds)
	check before the PATCH. The committed value is seconds.
-->

<script lang="ts">
	import type { CellEditorProps, CommitMove } from './types.js';
	import { coerceScalar } from '../coerce.js';
	import { parseDuration } from '$lib/components/primitives/forms/durationMath.js';

	let { field, value, seed = null, label, ondraft, oncommit, oncancel }: CellEditorProps =
		$props();

	// svelte-ignore state_referenced_locally — seed-only: the editor mounts
	// fresh per open; the draft starts from the cell's value and the seed
	// char, then the input owns it.
	let draft = $state(seed ?? (value == null ? '' : String(value)));
	let error = $state<string | null>(null);

	const ariaLabel = $derived(label ?? field.title ?? field.key);

	/** The parsed preview, or `null` while the text parses to nothing. */
	const preview = $derived.by<number | null>(() => {
		const text = draft.trim();
		if (text === '') return null;
		return parseDuration(text);
	});

	function fmt(seconds: number): string {
		const d = Math.floor(seconds / 86400);
		const h = Math.floor((seconds % 86400) / 3600);
		const mi = Math.floor((seconds % 3600) / 60);
		const s = seconds % 60;
		const parts = [
			d > 0 ? `${d}d` : null,
			h > 0 ? `${h}h` : null,
			mi > 0 ? `${mi}m` : null,
			!d && !h && !mi ? `${s}s` : s > 0 ? `${s}s` : null
		].filter(Boolean);
		return parts.join(' ') || '0s';
	}

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

{#if preview != null}
	<span class="dur-preview" aria-hidden="true">{fmt(preview)}</span>
{/if}
<input
	use:focusEnd
	class="cell-input"
	type="text"
	bind:value={draft}
	aria-label={ariaLabel}
	placeholder="2h 30m"
	class:invalid={error != null}
	title={error ?? undefined}
	oninput={publish}
	onkeydown={handleKeydown}
/>

<style>
	.dur-preview {
		font-size: 11px;
		color: var(--text-3);
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
