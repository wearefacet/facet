<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	The enum editor — a filter-as-you-type listbox over the field's declared
	values (the design mock's combobox). Typing narrows by key or label;
	ArrowDown / ArrowUp move the highlight, Enter picks it (an empty draft
	commits `null` — the clear), Tab picks and moves right, Escape cancels.
	Options reuse the cell's chip rendering: declared colour as tint + dot,
	label in the theme ink.
-->

<script lang="ts">
	import type { CellEditorProps, CommitMove } from './types.js';
	import { coerceScalar } from '../coerce.js';
	import { humanize } from '$lib/doctype/types.js';

	// The stored value never seeds the filter — the listbox opens on the
	// full declared set (the design mock's combobox behaviour).
	let { field, seed = null, label, ondraft, oncommit, oncancel }: CellEditorProps = $props();

	let inputEl = $state<HTMLInputElement | null>(null);
	// svelte-ignore state_referenced_locally — seed-only: the editor mounts
	// fresh per open; the filter starts from the seed char, then the input
	// owns it.
	let draft = $state(seed ?? '');
	let active = $state(0);

	const ariaLabel = $derived(label ?? field.title ?? field.key);

	/** The declared values narrowed by the draft — key or label, either case. */
	const options = $derived.by(() => {
		const values = field.values ?? [];
		const q = draft.trim().toLowerCase();
		if (q === '') return values;
		return values.filter(
			(e) =>
				e.key.toLowerCase().includes(q) || (e.label ?? '').toLowerCase().includes(q)
		);
	});

	/** The option the draft names exactly — published as the live draft. */
	const exactMatch = $derived.by(() => {
		if (draft.trim() === '') return { ok: true, value: null } as const;
		return coerceScalar(field, draft);
	});

	function focusEnd(node: HTMLInputElement): void {
		node.focus();
		const n = node.value.length;
		node.setSelectionRange(n, n);
	}

	function publish(): void {
		ondraft?.(exactMatch.ok ? exactMatch.value : draft, false);
	}

	function pick(key: string, move: CommitMove): void {
		ondraft?.(key, true);
		oncommit(key, move);
	}

	function commitActiveOrClear(move: CommitMove): void {
		if (draft.trim() === '') {
			// An empty draft commits the clear — never the first option.
			ondraft?.(null, true);
			oncommit(null, move);
			return;
		}
		const current = options[active];
		if (current) {
			pick(current.key, move);
			return;
		}
		// No highlighted option: accept an exact text match, else block.
		const result = coerceScalar(field, draft);
		if (result.ok) {
			ondraft?.(result.value, true);
			oncommit(result.value, move);
		}
	}

	function handleKeydown(e: KeyboardEvent): void {
		if (e.key === 'ArrowDown') {
			e.preventDefault();
			if (options.length > 0) active = (active + 1) % options.length;
		} else if (e.key === 'ArrowUp') {
			e.preventDefault();
			if (options.length > 0) active = (active - 1 + options.length) % options.length;
		} else if (e.key === 'Enter') {
			e.preventDefault();
			commitActiveOrClear('down');
		} else if (e.key === 'Tab') {
			e.preventDefault();
			commitActiveOrClear(e.shiftKey ? null : 'right');
		} else if (e.key === 'Escape') {
			e.preventDefault();
			e.stopPropagation();
			oncancel();
		}
	}

	function optionColor(key: string): string {
		return field.values?.find((e) => e.key === key)?.color ?? 'var(--text-3)';
	}

	function optionLabel(key: string): string {
		const entry = field.values?.find((e) => e.key === key);
		return entry?.label ?? humanize(key);
	}
</script>

<input
	bind:this={inputEl}
	use:focusEnd
	class="cell-input"
	type="text"
	bind:value={draft}
	aria-label={ariaLabel}
	role="combobox"
	aria-expanded="true"
	aria-controls="grid-enum-listbox"
	aria-autocomplete="list"
	oninput={() => {
		active = 0;
		publish();
	}}
	onkeydown={handleKeydown}
/>
<ul class="enum-list" id="grid-enum-listbox" role="listbox">
	{#each options as entry, i (entry.key)}
		<li role="presentation">
			<button
				type="button"
				class="enum-opt"
				class:active={i === active}
				role="option"
				aria-selected={i === active}
				onmousedown={(e) => {
					// mousedown keeps the input's focus from blurring first.
					e.preventDefault();
					pick(entry.key, null);
				}}
				onmouseenter={() => (active = i)}
			>
				<span class="enum-dot" style={`background: ${optionColor(entry.key)}`}></span>
				{optionLabel(entry.key)}
			</button>
		</li>
	{:else}
		<li class="enum-empty" role="presentation">—</li>
	{/each}
</ul>

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

	.enum-list {
		position: absolute;
		top: calc(100% + 2px);
		left: -2px;
		right: auto;
		min-width: 200px;
		max-height: 220px;
		overflow-y: auto;
		margin: 0;
		padding: 4px;
		list-style: none;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-sm, 6px);
		box-shadow: 0 8px 24px rgba(16, 24, 40, 0.25);
		z-index: 40;
	}

	.enum-opt {
		display: flex;
		align-items: center;
		gap: 8px;
		width: 100%;
		border: 0;
		background: none;
		padding: 6px 8px;
		border-radius: 4px;
		font-family: var(--font-sans);
		font-size: 13px;
		color: var(--text);
		cursor: pointer;
		text-align: left;
	}

	.enum-opt.active {
		background: var(--accent-weak);
	}

	.enum-dot {
		width: 7px;
		height: 7px;
		border-radius: 50%;
		flex-shrink: 0;
	}

	.enum-empty {
		padding: 6px 8px;
		font-size: 12px;
		color: var(--text-3);
	}
</style>
