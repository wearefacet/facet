<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import type { FieldDef } from '$lib/doctype/types.js';
	import type { CollectionViewColumn } from '$lib/collectionView/types.js';
	import { remainingFields } from '$lib/collectionView/config.js';

	/**
	 * Table-surface column builder — the picklist of available fields next to
	 * the ordered, labelled column list. The columns array lives in the
	 * parent; every mutation is reported through a callback so the parent
	 * keeps replacing the array instead of mutating the shared proxy.
	 */
	let {
		fields,
		columns,
		error = null,
		onadd,
		onremove,
		onmove,
		onlabel,
		oneditable
	}: {
		/** Pickable fields (flat doctype fields + system timestamps). */
		fields: FieldDef[];
		/** Ordered, authored columns. */
		columns: CollectionViewColumn[];
		/** Set when no column is selected. */
		error?: string | null;
		/** Add a field as a new column. */
		onadd: (field: FieldDef) => void;
		/** Remove the column at the index. */
		onremove: (index: number) => void;
		/** Move the column at the index by one position. */
		onmove: (index: number, dir: -1 | 1) => void;
		/** Patch the header label of the column at the index. */
		onlabel: (index: number, value: string) => void;
		/** Toggle inline editing for the (boolean) column at the index. */
		oneditable: (index: number, value: boolean) => void;
	} = $props();

	/** Pickable entries not yet added as columns. */
	const remaining = $derived(remainingFields(fields, columns));

	/** Whether any pickable field is a plain boolean — drives the helper line. */
	const hasBooleanFields = $derived(fields.some((f) => f.type === 'boolean'));
</script>

<div class="cve-field">
	<div class="cve-columns-head">
		<span class="cve-field-label">{m.list_editor_columns()}</span>
		{#if error}<span class="cve-field-err">{error}</span>{/if}
	</div>
	<div class="cve-columns">
		<div class="cve-col-pane" aria-label={m.list_editor_available_aria()}>
			<div class="cve-pane-head">{m.list_editor_available()}</div>
			<ul class="cve-picklist">
				{#each remaining as f (f.key)}
					<li>
						<button
							type="button"
							class="cve-pick"
							aria-label={m.list_editor_add_column_aria({ field: f.key })}
							onclick={() => onadd(f)}
						>
							<span class="cve-pick-key">{f.key}</span>
							{#if f.title && f.title !== f.key}
								<span class="cve-pick-title">{f.title}</span>
							{/if}
							<span class="cve-pick-add" aria-hidden="true">+</span>
						</button>
					</li>
				{:else}
					<li class="cve-empty">{m.list_editor_fields_exhausted()}</li>
				{/each}
			</ul>
		</div>
		<div class="cve-col-pane" aria-label={m.list_editor_selected_aria()}>
			<div class="cve-pane-head">
				{m.list_editor_selected_count({ count: columns.length })}
			</div>
			<ol class="cve-selected">
				{#each columns as col, i (col.key)}
					<li class="cve-col-row">
						<div class="cve-col-controls">
							<button
								type="button"
								class="cve-order"
								aria-label={m.list_editor_move_up_aria()}
								disabled={i === 0}
								onclick={() => onmove(i, -1)}>▲</button
							>
							<button
								type="button"
								class="cve-order"
								aria-label={m.list_editor_move_down_aria()}
								disabled={i === columns.length - 1}
								onclick={() => onmove(i, 1)}>▼</button
							>
						</div>
						<div class="cve-col-fields">
							<input
								class="cve-col-label"
								aria-label={m.list_editor_label_aria({ field: col.key })}
								value={col.label ?? col.key}
								oninput={(e) => onlabel(i, (e.currentTarget as HTMLInputElement).value)}
							/>
							<span class="cve-col-key">{col.key}</span>
							{#if fields.find((f) => f.key === col.key)?.type === 'boolean'}
								<label class="cve-col-inline">
									<input
										type="checkbox"
										checked={col.editable === true}
										aria-label={m.list_editor_inline_aria({ field: col.key })}
										onchange={(e) => oneditable(i, (e.currentTarget as HTMLInputElement).checked)}
									/>
									{m.list_editor_inline_label()}
								</label>
							{/if}
						</div>
						<button
							type="button"
							class="cve-remove"
							aria-label={m.list_editor_remove_column_aria({ field: col.key })}
							onclick={() => onremove(i)}>✕</button
						>
					</li>
				{:else}
					<li class="cve-empty">{m.list_editor_no_columns()}</li>
				{/each}
			</ol>
		</div>
	</div>
	{#if hasBooleanFields}
		<span class="cve-inline-helper">{m.list_editor_inline_helper()}</span>
	{/if}
</div>

<style>
	.cve-field {
		display: flex;
		flex-direction: column;
		gap: 6px;
	}

	.cve-field-label {
		font-size: 12.5px;
		font-weight: 500;
		color: var(--text-2);
	}

	.cve-field-err,
	.cve-columns-head .cve-field-err {
		font-size: 11.5px;
		color: var(--danger);
	}

	.cve-columns-head {
		display: flex;
		align-items: baseline;
		gap: 10px;
	}

	.cve-columns {
		display: grid;
		grid-template-columns: 1fr 1fr;
		gap: 10px;
		border: 1px solid var(--border);
		border-radius: var(--r);
		overflow: hidden;
	}

	.cve-col-pane {
		display: flex;
		flex-direction: column;
		min-height: 200px;
		max-height: 280px;
		background: var(--surface);
	}

	.cve-pane-head {
		padding: 8px 12px;
		font-size: 11.5px;
		font-weight: 600;
		color: var(--text-3);
		text-transform: uppercase;
		letter-spacing: 0.04em;
		border-bottom: 1px solid var(--border);
		background: var(--surface-2);
	}

	.cve-picklist,
	.cve-selected {
		list-style: none;
		margin: 0;
		padding: 4px;
		overflow-y: auto;
		flex: 1;
	}

	.cve-pick {
		display: flex;
		align-items: center;
		gap: 8px;
		width: 100%;
		padding: 6px 8px;
		border: none;
		background: none;
		border-radius: var(--r-sm, 6px);
		cursor: pointer;
		text-align: left;
		font: inherit;
		color: var(--text);
	}

	.cve-pick:hover {
		background: var(--sunken);
	}

	.cve-pick-key {
		font-family: var(--font-mono);
		font-size: 12px;
	}

	.cve-pick-title {
		font-size: 11.5px;
		color: var(--text-3);
		flex: 1;
	}

	.cve-pick-add {
		margin-left: auto;
		color: var(--accent);
		font-weight: 600;
	}

	.cve-col-row {
		display: flex;
		align-items: center;
		gap: 6px;
		padding: 4px 6px;
		border-radius: var(--r-sm, 6px);
	}

	.cve-col-row:hover {
		background: var(--sunken);
	}

	.cve-col-controls {
		display: flex;
		flex-direction: column;
		gap: 1px;
	}

	.cve-order,
	.cve-remove {
		width: 20px;
		height: 16px;
		border: none;
		background: none;
		color: var(--text-3);
		cursor: pointer;
		font-size: 9px;
		line-height: 1;
		border-radius: 3px;
		padding: 0;
		display: flex;
		align-items: center;
		justify-content: center;
	}

	.cve-order:hover:not(:disabled),
	.cve-remove:hover {
		background: var(--border);
		color: var(--text);
	}

	.cve-order:disabled {
		opacity: 0.3;
		cursor: not-allowed;
	}

	.cve-remove {
		color: var(--danger);
		font-size: 11px;
		height: 20px;
	}

	.cve-col-fields {
		display: flex;
		flex-direction: column;
		gap: 2px;
		flex: 1;
		min-width: 0;
	}

	.cve-col-key {
		font-family: var(--font-mono);
		font-size: 11px;
		color: var(--text-3);
	}

	.cve-col-inline {
		display: inline-flex;
		align-items: center;
		gap: 4px;
		font-size: 11px;
		color: var(--text-2);
		cursor: pointer;
		user-select: none;
	}

	.cve-col-inline input {
		accent-color: var(--accent);
		margin: 0;
	}

	.cve-inline-helper {
		font-size: 11.5px;
		color: var(--text-3);
	}

	.cve-col-label {
		font: inherit;
		font-size: 12.5px;
		padding: 3px 6px;
		border: 1px solid var(--border);
		border-radius: var(--r-sm, 6px);
		background: var(--surface);
		color: var(--text);
		outline: none;
		min-width: 0;
	}

	.cve-col-label:focus {
		border-color: var(--accent);
		box-shadow: 0 0 0 2px var(--accent-weak);
	}

	.cve-empty {
		padding: 12px 8px;
		font-size: 12px;
		color: var(--text-3);
		text-align: center;
	}
</style>
