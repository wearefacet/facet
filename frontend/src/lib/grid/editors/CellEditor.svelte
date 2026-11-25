<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	The cell editor shell — one frame over the existing form inputs, not
	twelve bespoke editors. The shell picks the per-type editor from the
	field's type, provides the shared in-cell frame (the accent border the
	design mock draws), and answers the outside-commit request: when another
	cell takes the mousedown, the shell commits the live draft (or cancels
	an unparseable one), so a stray click never eats the typed text.

	The `longtext` and the datetime-range editors float above the cell; the
	rest fill the cell box. The grid mounts one shell per open editor and
	drives the write through `oncommit`.
-->

<script lang="ts">
	import type { CellEditorProps, CommitMove } from './types.js';
	import TextEditor from './TextEditor.svelte';
	import LongTextEditor from './LongTextEditor.svelte';
	import IntegerEditor from './IntegerEditor.svelte';
	import DurationEditor from './DurationEditor.svelte';
	import EnumEditor from './EnumEditor.svelte';
	import MoneyEditor from './MoneyEditor.svelte';
	import DateEditor from './DateEditor.svelte';
	import PeriodEditor from './PeriodEditor.svelte';
	import ReferenceEditor from './ReferenceEditor.svelte';
	import ColorEditor from './ColorEditor.svelte';

	let { field, label, ...rest }: CellEditorProps = $props();

	/** The live draft the active editor last published — the outside commit
	 *  reads it. `valid: false` keeps the commit from writing a bad value. */
	let draft: { value: unknown; valid: boolean } | null = null;

	function handleDraft(value: unknown, valid: boolean): void {
		draft = { value, valid };
	}

	function handleCommit(value: unknown, move: CommitMove): void {
		draft = null;
		rest.oncommit(value, move);
	}

	function handleCancel(): void {
		draft = null;
		rest.oncancel();
	}

	/** Another cell took the mousedown — commit a valid draft, else cancel. */
	export function commitFromOutside(): void {
		if (!draft) {
			handleCancel();
			return;
		}
		const { value, valid } = draft;
		draft = null;
		if (valid) rest.oncommit(value, null);
		else rest.oncancel();
	}

	/** The floating editors — the frame grows past the cell box. The
	 *  datetime picker and the period pair also widen past the cell: five
	 *  segments (or two bound pickers) never fit one column, and clipping
	 *  them would hide the time part (or the End bound). */
	const floating = $derived(
		field.type === 'longtext' ||
			field.type === 'datetime' ||
			field.type === 'period' ||
			field.type === 'dateperiod'
	);
	const wide = $derived(
		field.type === 'datetime' || field.type === 'period' || field.type === 'dateperiod'
	);
</script>

<!-- svelte-ignore a11y_no_static_element_interactions -->
<!-- A press inside the editor belongs to the editor: the shell stops it
	from reaching the grid's cells, so it never arms the drag-select (the
	enum list closes the editor under the held button — without this, the
	cells exposed underneath sweep-select). -->
<div
	class="cell-editor"
	class:floating
	class:wide
	onmousedown={(e) => e.stopPropagation()}
>
	{#if field.type === 'longtext'}
		<LongTextEditor {field} {label} {...rest} ondraft={handleDraft} oncommit={handleCommit} oncancel={handleCancel} />
	{:else if field.type === 'enum'}
		<EnumEditor {field} {label} {...rest} ondraft={handleDraft} oncommit={handleCommit} oncancel={handleCancel} />
	{:else if field.type === 'integer'}
		<IntegerEditor {field} {label} {...rest} ondraft={handleDraft} oncommit={handleCommit} oncancel={handleCancel} />
	{:else if field.type === 'duration'}
		<DurationEditor {field} {label} {...rest} ondraft={handleDraft} oncommit={handleCommit} oncancel={handleCancel} />
	{:else if field.type === 'money'}
		<MoneyEditor {field} {label} {...rest} ondraft={handleDraft} oncommit={handleCommit} oncancel={handleCancel} />
	{:else if field.type === 'date' || field.type === 'datetime'}
		<DateEditor {field} {label} {...rest} ondraft={handleDraft} oncommit={handleCommit} oncancel={handleCancel} />
	{:else if field.type === 'period' || field.type === 'dateperiod'}
		<PeriodEditor {field} {label} {...rest} ondraft={handleDraft} oncommit={handleCommit} oncancel={handleCancel} />
	{:else if field.type === 'reference'}
		<ReferenceEditor {field} {label} {...rest} ondraft={handleDraft} oncommit={handleCommit} oncancel={handleCancel} />
	{:else if field.type === 'color'}
		<ColorEditor {field} {label} {...rest} ondraft={handleDraft} oncommit={handleCommit} oncancel={handleCancel} />
	{:else}
		<!-- `string`, `phone`, `url` — the bare text input. -->
		<TextEditor {field} {label} {...rest} ondraft={handleDraft} oncommit={handleCommit} oncancel={handleCancel} />
	{/if}
</div>

<style>
	.cell-editor {
		position: absolute;
		inset: 0;
		display: flex;
		align-items: center;
		background: var(--surface);
		border: 2px solid var(--accent);
		border-radius: var(--r-sm, 4px);
		z-index: 1;
		padding: 0 6px;
		min-width: 0;
	}

	.cell-editor.floating {
		inset: auto 0 auto 0;
		top: -1px;
		height: auto;
		z-index: 30;
		box-shadow: 0 8px 24px rgba(16, 24, 40, 0.25);
		padding: 6px;
		align-items: flex-start;
	}

	/* The period frame sizes to its two bound pickers — wider than the cell. */
	.cell-editor.floating.wide {
		right: auto;
		width: max-content;
		max-width: min(92vw, 560px);
	}
</style>
