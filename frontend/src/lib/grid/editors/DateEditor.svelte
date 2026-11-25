<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	The date / datetime editor — mounts the platform's `DatetimePicker` in
	its compact mode (bare segment field + calendar popover; the mode the
	picker's own docs name for inline grid cells). `date` fields commit a
	`YYYY-MM-DD` calendar date, `datetime` fields a UTC RFC-3339 instant —
	the picker's contract, passed through. A `datetime` frame floats over
	the cell and shows the parsed value while typing: the stored UTC form
	the complete segments will commit (the design mock's
	"31/01/2027 → 2027-01-31" rule) — a partial edit holds the last
	complete value, so the line reads what Enter would write. The compact
	mode hides the Clear action, so the editor adds one: a small ✕ at the
	frame's right commits `null`. Enter commits down, Tab right, Escape
	cancels.
-->

<script lang="ts">
	import type { CellEditorProps } from './types.js';
	import DatetimePicker from '$lib/components/primitives/forms/DatetimePicker.svelte';

	let { field, value, label, ondraft, oncommit, oncancel }: CellEditorProps = $props();

	// svelte-ignore state_referenced_locally — seed-only: the editor mounts
	// fresh per open; the binding seeds from the stored ISO string, then
	// the picker owns it.
	let draft = $state(typeof value === 'string' ? value : '');

	const ariaLabel = $derived(label ?? field.title ?? field.key);
	const dateOnly = $derived(field.type === 'date');

	// The picker writes the bindable only on a complete entry — a partial
	// edit never wipes a set value. Publish each write as the live draft.
	$effect(() => {
		const v = draft;
		ondraft?.(v === '' ? null : v, true);
	});

	function handleKeydown(e: KeyboardEvent): void {
		if (e.key === 'Enter' || e.key === 'Tab') {
			e.preventDefault();
			oncommit(draft === '' ? null : draft, e.key === 'Enter' ? 'down' : e.shiftKey ? null : 'right');
		} else if (e.key === 'Escape') {
			e.preventDefault();
			e.stopPropagation();
			oncancel();
		}
	}

	/** Mount action — the year segment takes the focus, ready to type. */
	function focusFirstSegment(node: HTMLElement): void {
		node.querySelector<HTMLInputElement>('input')?.focus();
	}
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div class="date-editor" onkeydown={handleKeydown} use:focusFirstSegment>
	<div class="date-editor-row">
		<DatetimePicker
			compact
			granularity={dateOnly ? 'date' : 'datetime'}
			bind:value={draft}
			label={ariaLabel}
		/>
		<button
			type="button"
			class="clear-btn"
			aria-label={ariaLabel}
			title={ariaLabel}
			onclick={() => {
				draft = '';
				oncommit(null, null);
			}}
		>
			✕
		</button>
	</div>
	{#if !dateOnly && draft !== ''}
		<!-- The parsed value — the stored UTC form the segments commit. -->
		<div class="parsed-hint">→ {draft}</div>
	{/if}
</div>

<style>
	.date-editor {
		flex: 1;
		min-width: 0;
		height: 100%;
		display: flex;
		flex-direction: column;
		justify-content: center;
		gap: 3px;
	}

	.date-editor-row {
		display: flex;
		align-items: center;
		gap: 4px;
		min-width: 0;
	}

	.date-editor-row :global(.dtp-wrap) {
		flex: 1;
		min-width: 0;
	}

	.date-editor-row :global(.dtp-field) {
		background: none;
		border: none;
		padding: 0;
		height: 100%;
	}

	.date-editor-row :global(.dtp-seg) {
		font-family: var(--font-mono);
		font-size: 12.5px;
		color: var(--text);
		background: none;
		padding: 0;
	}

	/* The parsed value under the segments — data, so mono, and muted: the
	   typed segments carry the entry, this carries the committed form. */
	.parsed-hint {
		font-family: var(--font-mono);
		font-variant-ligatures: none;
		font-size: 10.5px;
		color: var(--text-3);
		white-space: nowrap;
	}

	.clear-btn {
		border: 0;
		background: none;
		color: var(--text-3);
		font-size: 11px;
		padding: 2px 4px;
		border-radius: 4px;
		cursor: pointer;
		flex-shrink: 0;
	}

	.clear-btn:hover {
		color: var(--danger);
		background: var(--surface-2);
	}
</style>
