<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	The period / dateperiod editor — mounts the platform's `PeriodPicker`
	(`mode: 'date'` for `dateperiod`, `mode: 'datetime'` for `period`) in a
	floating frame over the cell: the picker's two bound editors need more
	room than one 40px row. The picker's own commit rule passes through —
	the pair commits only complete, `''` only cleared; a partial edit never
	wipes a set range. Enter commits down, Tab right, Escape cancels.
-->

<script lang="ts">
	import type { CellEditorProps } from './types.js';
	import PeriodPicker from '$lib/components/primitives/forms/PeriodPicker.svelte';
	import * as m from '$lib/paraglide/messages';

	let { field, value, label, ondraft, oncommit, oncancel }: CellEditorProps = $props();

	type PeriodValue = { start: string; end: string } | '';

	// svelte-ignore state_referenced_locally — seed-only: the editor mounts
	// fresh per open; the binding seeds from the stored range, then the
	// picker owns it.
	let draft = $state<PeriodValue>(
		value != null && typeof value === 'object'
			? {
					start: String((value as Record<string, unknown>).start ?? ''),
					end: String((value as Record<string, unknown>).end ?? '')
				}
			: ''
	);

	const ariaLabel = $derived(label ?? field.title ?? field.key);
	const mode = $derived(field.type === 'dateperiod' ? 'date' : 'datetime');

	$effect(() => {
		const v = draft;
		ondraft?.(v === '' ? null : v, true);
	});

	function handleKeydown(e: KeyboardEvent): void {
		if (e.key === 'Enter' || e.key === 'Tab') {
			e.preventDefault();
			oncommit(
				draft === '' ? null : draft,
				e.key === 'Enter' ? 'down' : e.shiftKey ? null : 'right'
			);
		} else if (e.key === 'Escape') {
			e.preventDefault();
			e.stopPropagation();
			oncancel();
		}
	}

	/** Mount action — the Start bound's first segment takes the focus. */
	function focusFirstSegment(node: HTMLElement): void {
		node.querySelector<HTMLInputElement>('input')?.focus();
	}
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<div class="period-editor" onkeydown={handleKeydown} use:focusFirstSegment>
	<div class="period-editor-head">
		<span class="period-editor-title">{ariaLabel}</span>
		<button
			type="button"
			class="clear-btn"
			aria-label={m.common_clear()}
			onclick={() => {
				draft = '';
				oncommit(null, null);
			}}
		>
			{m.common_clear()}
		</button>
	</div>
	<PeriodPicker {mode} bind:value={draft} />
</div>

<style>
	.period-editor {
		flex: 1;
		min-width: 0;
		background: var(--surface);
		padding: 4px 2px;
	}

	.period-editor-head {
		display: flex;
		align-items: center;
		justify-content: space-between;
		gap: 8px;
		margin-bottom: 2px;
	}

	.period-editor-title {
		font-size: 11px;
		font-weight: 600;
		color: var(--text-2);
	}

	.clear-btn {
		border: 0;
		background: none;
		color: var(--text-3);
		font-size: 11px;
		padding: 1px 6px;
		border-radius: 4px;
		cursor: pointer;
	}

	.clear-btn:hover {
		color: var(--danger);
		background: var(--surface-2);
	}

	/* The floating frame replaces the picker's chrome: no nested box border,
	   no second Clear — the head owns the clear. The committed-text foot
	   stays: the parsed `start → end` pair the bounds will commit, the same
	   rule the datetime editor's parsed line follows. */
	.period-editor :global(.pp-box) {
		border: none;
		padding: 0;
	}

	.period-editor :global(.pp-box:focus-within) {
		box-shadow: none;
	}

	.period-editor :global(.pp-actions) {
		display: none;
	}
</style>
