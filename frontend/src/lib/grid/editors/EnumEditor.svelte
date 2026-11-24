<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	The enum editor — a filter-as-you-type listbox over the field's declared
	values (the design mock's combobox). The stored value stays visible as a
	chip beside the filter input, and its option carries the check mark and
	the opening highlight. Typing narrows by key or label; ArrowDown /
	ArrowUp move the highlight, Enter picks it. An empty draft keeps the
	stored value (open + Enter never wipes); the chip's ✕ is the clear.
	Tab picks and moves right, Escape cancels. Options reuse the cell's chip
	rendering: declared colour as tint + dot, label in the theme ink.
-->

<script lang="ts">
	import type { CellEditorProps, CommitMove } from './types.js';
	import { coerceScalar } from '../coerce.js';
	import { humanize } from '$lib/doctype/types.js';
	import * as m from '$lib/paraglide/messages';

	let { field, value, seed = null, label, ondraft, oncommit, oncancel }: CellEditorProps = $props();

	let inputEl = $state<HTMLInputElement | null>(null);

	// The filter opens on the full declared set — the stored value shows as
	// the chip, not as filter text.
	// svelte-ignore state_referenced_locally — seed-only: the editor mounts
	// fresh per open; the filter starts empty (or from the seed char), then
	// the input owns it.
	let draft = $state(seed ?? '');
	// svelte-ignore state_referenced_locally — seed-only: the highlight
	// starts on the stored value's option, then the keyboard owns it.
	let active = $state(
		Math.max(0, (field.values ?? []).findIndex((e) => e.key === (typeof value === 'string' ? value : '')))
	);

	const ariaLabel = $derived(label ?? field.title ?? field.key);

	/** The stored value at open time — the chip, the check mark, and the
	 *  keep-on-empty commit rule all read it. */
	const currentKey = $derived(typeof value === 'string' && value !== '' ? value : null);
	const currentEntry = $derived(
		currentKey ? field.values?.find((e) => e.key === currentKey) : undefined
	);
	const currentLabel = $derived(currentKey ? (currentEntry?.label ?? humanize(currentKey)) : '');
	const currentColor = $derived(currentKey ? (currentEntry?.color ?? 'var(--text-3)') : 'transparent');

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

	/** The chip's ✕ — one click clears the field and closes. */
	function clearAll(): void {
		ondraft?.(null, true);
		oncommit(null, null);
	}

	function commitActiveOrClear(move: CommitMove): void {
		if (draft.trim() === '') {
			// An empty draft keeps the stored value — open + Enter never wipes.
			// Without a stored value it commits the clear (a no-op close).
			if (currentKey) pick(currentKey, move);
			else {
				ondraft?.(null, true);
				oncommit(null, move);
			}
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

	/** `aria-activedescendant` target for the highlighted option. */
	const activeId = $derived(options.length > 0 ? `grid-enum-opt-${active}` : undefined);
</script>

{#if currentKey}
	<span class="enum-current">
		<span class="enum-dot" style={`background: ${currentColor}`}></span>
		<span class="enum-current-label">{currentLabel}</span>
		<button
			type="button"
			class="enum-current-clear"
			aria-label={m.common_clear()}
			onmousedown={(e) => {
				// mousedown keeps the input's focus from blurring first.
				e.preventDefault();
				clearAll();
			}}
		>✕</button>
	</span>
{/if}
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
	aria-activedescendant={activeId}
	placeholder={m.grid_enum_filter()}
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
				id={`grid-enum-opt-${i}`}
				role="option"
				aria-selected={entry.key === currentKey}
				onmousedown={(e) => {
					// mousedown keeps the input's focus from blurring first.
					e.preventDefault();
					pick(entry.key, null);
				}}
				onmouseenter={() => (active = i)}
			>
				<span class="enum-dot" style={`background: ${optionColor(entry.key)}`}></span>
				{optionLabel(entry.key)}
				{#if entry.key === currentKey}
					<span class="enum-check" aria-hidden="true">✓</span>
				{/if}
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

	.cell-input::placeholder {
		color: var(--text-3);
	}

	/* The stored value stays visible while the editor is open. */
	.enum-current {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		flex: none;
		max-width: 62%;
		padding: 2px 4px 2px 8px;
		border-radius: 999px;
		background: var(--surface-2);
		font-size: 12px;
		color: var(--text);
	}

	.enum-current-label {
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
	}

	.enum-current-clear {
		all: unset;
		display: grid;
		place-items: center;
		width: 14px;
		height: 14px;
		border-radius: 50%;
		font-size: 9px;
		line-height: 1;
		color: var(--text-3);
		cursor: pointer;
	}

	.enum-current-clear:hover {
		color: var(--danger);
		background: var(--surface);
	}

	.enum-current-clear:focus-visible {
		outline: 2px solid var(--accent);
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

	.enum-check {
		margin-left: auto;
		font-size: 11px;
		color: var(--accent);
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
