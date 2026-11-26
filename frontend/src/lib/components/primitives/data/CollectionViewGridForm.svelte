<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { DoctypeDef, FieldDef } from '$lib/doctype/types.js';
	import type { CollectionViewColumn, GridColumnSummary } from '$lib/collectionView/types.js';
	import {
		fieldOptions,
		pickableFields,
		remainingFields,
		sortableFields
	} from '$lib/collectionView/config.js';
	import { isAggregatableField, isWritableField } from '$lib/grid/fieldTypes.js';
	import Select from '$lib/components/primitives/forms/Select.svelte';
	import FilterBar from '$lib/components/primitives/navigation/FilterBar.svelte';
	import Toggle from '$lib/components/primitives/forms/Toggle.svelte';

	/**
	 * Grid-surface configuration form — the spreadsheet step of the view
	 * editor. The grid settings (frozen columns, the ghost new-row opt-in),
	 * the two-pane column builder with the grid column semantics (the Edit
	 * opt-out on writable fields, the Σ summary picker), the row sort, and
	 * the embedded FilterBar.
	 *
	 * The draft values live in the parent; each bindable prop round-trips
	 * the writes so the parent keeps its one-time-initialised draft state
	 * (the kanban rule). Column mutations replace the array — never a
	 * shared-proxy write.
	 *
	 * Grid column semantics: a writable column is editable unless
	 * `editable: false`, so the Edit checkbox starts checked and unchecking
	 * persists the opt-out; checking again drops the flag so the stored
	 * config stays clean. A Σ field aggregate is offered only on the types
	 * the backend aggregates (`integer`, `duration`, `money` — see
	 * `fieldTypes.ts`); `count` runs field-free on any column.
	 */
	let {
		doctype,
		driver,
		columns = $bindable<CollectionViewColumn[]>([]),
		frozen = $bindable(0),
		allowCreate = $bindable(false),
		sortField = $bindable(''),
		sortDesc = $bindable(true),
		filters = $bindable<Record<string, unknown>>({}),
		columnsError = null
	}: {
		/** Parsed parent doctype definition (the pickers and FilterBar read its fields). */
		doctype: DoctypeDef;
		/** Driver used by the FilterBar to resolve `reference` filters. */
		driver: DataDriver;
		/** Ordered, authored columns — the array the grid shares with the table. */
		columns?: CollectionViewColumn[];
		/** Leading columns pinned left, after the gutter and checkbox. */
		frozen?: number;
		/** The ghost new-row line is on. */
		allowCreate?: boolean;
		/** Row sort field; empty means the surface default. */
		sortField?: string;
		/** Row sort direction (descending when true — the `-` prefix). */
		sortDesc?: boolean;
		/** Active base filters, keyed by `field__op`. Stale keys drop at
		 *  build time (`buildConfig` runs `dropUnknownFilter` against the
		 *  editor's filterable set). */
		filters?: Record<string, unknown>;
		/** Set when no column is selected. */
		columnsError?: string | null;
	} = $props();

	// ── Field resolution ─────────────────────────────────────────────
	/** The picker pool — flat schema fields plus the system timestamps. */
	const pickable = $derived(pickableFields(doctype.fields));

	/** Any pickable entry (the system timestamps included) — drives the
	 *  type badge and the summary options. */
	function fieldFor(key: string): FieldDef | null {
		return pickable.find((f) => f.key === key) ?? null;
	}

	/** Schema fields the grid can write — the system timestamps never
	 *  resolve here (they render but never edit), nor do `read_only` /
	 *  `write_only` / non-writable types. */
	function schemaWritable(key: string): FieldDef | null {
		const f = doctype.fields.find((def) => def.key === key) ?? null;
		return f !== null && isWritableField(f) ? f : null;
	}

	// ── Picker sections ──────────────────────────────────────────────
	/** `write_only` fields are never a column (the server masks them) —
	 *  the picker does not offer them either. */
	const remaining = $derived(remainingFields(pickable, columns).filter((f) => !f.write_only));
	const editableRemaining = $derived(remaining.filter((f) => schemaWritable(f.key) !== null));
	const readonlyRemaining = $derived(remaining.filter((f) => schemaWritable(f.key) === null));

	// ── Option lists ─────────────────────────────────────────────────
	const frozenOptions = $derived.by(() => {
		const options: { value: string; label: string }[] = [];
		for (let n = 1; n <= columns.length; n++) options.push({ value: String(n), label: String(n) });
		return options;
	});
	const sortOptions = $derived(fieldOptions(sortableFields(doctype.fields)));

	/** The Σ options for one column: `count` always, the field aggregates
	 *  only on an aggregate-able field type. */
	function summaryOptionsFor(col: CollectionViewColumn): { value: string; label: string }[] {
		const options: { value: string; label: string }[] = [
			{ value: 'count', label: m.grid_agg_count() }
		];
		const field = fieldFor(col.key);
		if (field && isAggregatableField(field)) {
			options.push(
				{ value: 'sum', label: m.grid_agg_sum() },
				{ value: 'avg', label: m.grid_agg_avg() },
				{ value: 'min', label: m.grid_agg_min() },
				{ value: 'max', label: m.grid_agg_max() }
			);
		}
		return options;
	}

	// ── Column mutations — array replacement, never a proxy write ────
	function addField(f: FieldDef) {
		columns = [...columns, { key: f.key, label: f.title ?? f.key }];
	}

	function removeColumn(index: number) {
		columns = columns.filter((_, i) => i !== index);
		// The frozen count pins leading columns — it never exceeds the set.
		if (frozen > columns.length) frozen = columns.length;
	}

	function moveColumn(index: number, dir: -1 | 1) {
		const target = index + dir;
		if (target < 0 || target >= columns.length) return;
		const next = [...columns];
		[next[index], next[target]] = [next[target], next[index]];
		columns = next;
	}

	function patchLabel(index: number, value: string) {
		const next = [...columns];
		next[index] = { ...next[index], label: value };
		columns = next;
	}

	/** Grid edit semantics — checked drops the flag (writable columns edit
	 *  by default), unchecked persists the `editable: false` opt-out. */
	function patchEditable(index: number, editable: boolean) {
		const next = [...columns];
		const col = { ...next[index] };
		if (editable) delete col.editable;
		else col.editable = false;
		next[index] = col;
		columns = next;
	}

	function patchSummary(index: number, summary: string) {
		const next = [...columns];
		const col = { ...next[index] };
		if (summary === '') delete col.summary;
		else col.summary = summary as GridColumnSummary;
		next[index] = col;
		columns = next;
	}
</script>

<div class="cve-field">
	<div class="cve-filters-head">
		<span class="cve-field-label">{m.list_editor_surface_grid()}</span>
		<span class="cve-field-helper">{m.list_editor_grid_frozen_helper()}</span>
	</div>
	<div class="grid-settings" role="group" aria-label={m.list_editor_surface_grid()}>
		<div class="grid-setting">
			<span class="cve-field-label">{m.list_editor_grid_frozen()}</span>
			<select
				class="grid-frozen"
				aria-label={m.list_editor_grid_frozen()}
				value={String(frozen)}
				onchange={(e) => (frozen = Number((e.currentTarget as HTMLSelectElement).value))}
			>
				<option value="0">{m.common_none()}</option>
				{#each frozenOptions as opt (opt.value)}
					<option value={opt.value}>{opt.label}</option>
				{/each}
			</select>
		</div>
		<div class="grid-setting">
			<span class="cve-field-label">{m.list_editor_grid_allow_create()}</span>
			<div class="grid-toggle">
				<Toggle
					checked={allowCreate}
					aria-label={m.list_editor_grid_allow_create()}
					onchange={(checked) => (allowCreate = checked)}
				/>
				<span class="cve-field-helper">{m.list_editor_grid_allow_create_helper()}</span>
			</div>
		</div>
	</div>
</div>

<div class="cve-field">
	<div class="cve-columns-head">
		<span class="cve-field-label">{m.list_editor_columns()}</span>
		{#if columnsError}<span class="cve-field-err">{columnsError}</span>{/if}
	</div>
	<div class="cve-columns">
		<div class="cve-col-pane" aria-label={m.list_editor_available_aria()}>
			<div class="cve-pane-head">{m.list_editor_available()}</div>
			{#if editableRemaining.length > 0}
				<div class="cve-pane-sec">{m.list_editor_grid_section_editable()}</div>
				<ul class="cve-picklist">
					{#each editableRemaining as f (f.key)}
						<li>
							<button
								type="button"
								class="cve-pick"
								aria-label={m.list_editor_add_column_aria({ field: f.key })}
								onclick={() => addField(f)}
							>
								<span class="cve-pick-key">{f.key}</span>
								{#if f.title && f.title !== f.key}
									<span class="cve-pick-title">{f.title}</span>
								{/if}
								<span class="cve-pick-type">{f.type}</span>
								<span class="cve-pick-add" aria-hidden="true">+</span>
							</button>
						</li>
					{/each}
				</ul>
			{/if}
			{#if readonlyRemaining.length > 0}
				<div class="cve-pane-sec">{m.list_editor_grid_section_readonly()}</div>
				<ul class="cve-picklist">
					{#each readonlyRemaining as f (f.key)}
						<li>
							<button
								type="button"
								class="cve-pick"
								aria-label={m.list_editor_add_column_aria({ field: f.key })}
								onclick={() => addField(f)}
							>
								<span class="cve-pick-key">{f.key}</span>
								{#if f.title && f.title !== f.key}
									<span class="cve-pick-title">{f.title}</span>
								{/if}
								<span class="cve-pick-type">{f.type}</span>
								<span class="cve-pick-add" aria-hidden="true">+</span>
							</button>
						</li>
					{/each}
				</ul>
			{/if}
			{#if editableRemaining.length === 0 && readonlyRemaining.length === 0}
				<ul class="cve-picklist">
					<li class="cve-empty">{m.list_editor_fields_exhausted()}</li>
				</ul>
			{/if}
		</div>
		<div class="cve-col-pane" aria-label={m.list_editor_selected_aria()}>
			<div class="cve-pane-head">{m.list_editor_selected_count({ count: columns.length })}</div>
			<ol class="cve-selected">
				{#each columns as col, i (col.key)}
					{@const field = fieldFor(col.key)}
					{@const writable = schemaWritable(col.key)}
					<li class="cve-col-row">
						<div class="cve-col-controls">
							<button
								type="button"
								class="cve-order"
								aria-label={m.list_editor_move_up_aria()}
								disabled={i === 0}
								onclick={() => moveColumn(i, -1)}>▲</button
							>
							<button
								type="button"
								class="cve-order"
								aria-label={m.list_editor_move_down_aria()}
								disabled={i === columns.length - 1}
								onclick={() => moveColumn(i, 1)}>▼</button
							>
						</div>
						<div class="cve-col-fields">
							<input
								class="cve-col-label"
								aria-label={m.list_editor_label_aria({ field: col.key })}
								value={col.label ?? col.key}
								oninput={(e) => patchLabel(i, (e.currentTarget as HTMLInputElement).value)}
							/>
							<div class="cve-col-meta">
								<span class="cve-col-key">{col.key}</span>
								{#if field}
									<span class="cve-col-type">{field.type}</span>
								{/if}
								{#if i < frozen}
									<span class="cve-col-frozen">{m.list_editor_grid_frozen_marker()}</span>
								{/if}
								{#if writable}
									<label class="cve-col-inline">
										<input
											type="checkbox"
											checked={col.editable !== false}
											aria-label={m.list_editor_grid_columns_editable_aria({ field: col.key })}
											onchange={(e) =>
												patchEditable(i, (e.currentTarget as HTMLInputElement).checked)}
										/>
										{m.list_editor_grid_columns_editable()}
									</label>
								{/if}
								<span class="cve-col-summary">
									<span class="cve-col-summary-label">{m.list_editor_grid_summary()}</span>
									<select
										class="grid-summary"
										aria-label={m.list_editor_grid_summary_aria({ field: col.key })}
										value={col.summary ?? ''}
										onchange={(e) => patchSummary(i, (e.currentTarget as HTMLSelectElement).value)}
									>
										<option value="">{m.common_none()}</option>
										{#each summaryOptionsFor(col) as opt (opt.value)}
											<option value={opt.value}>{opt.label}</option>
										{/each}
									</select>
								</span>
								{#if field?.type === 'data'}
									<span class="cve-col-note">{m.grid_fx_read_only()}</span>
								{/if}
								{#if !field}
									<span class="cve-col-note cve-col-note-warn">
										{m.list_editor_grid_unknown_field()}
									</span>
								{/if}
							</div>
						</div>
						<button
							type="button"
							class="cve-remove"
							aria-label={m.list_editor_remove_column_aria({ field: col.key })}
							onclick={() => removeColumn(i)}>✕</button
						>
					</li>
				{:else}
					<li class="cve-empty">{m.list_editor_no_columns()}</li>
				{/each}
			</ol>
		</div>
	</div>
	<span class="cve-inline-helper">{m.list_editor_grid_columns_editable_helper()}</span>
</div>

<div class="cve-field">
	<div class="cve-filters-head">
		<span class="cve-field-label">{m.list_editor_grid_sort()}</span>
		<span class="cve-field-helper">{m.list_editor_grid_sort_helper()}</span>
	</div>
	<div class="grid-sort">
		<Select
			label={m.list_editor_grid_sort()}
			placeholder={m.list_editor_grid_sort_default()}
			options={sortOptions}
			bind:value={sortField}
		/>
		<div class="grid-dir" role="radiogroup" aria-label={m.list_editor_grid_sort_dir_aria()}>
			<button
				type="button"
				role="radio"
				aria-checked={!sortDesc}
				class="grid-dir-btn"
				class:grid-dir-on={!sortDesc}
				onclick={() => (sortDesc = false)}
			>
				{m.list_editor_grid_sort_asc()}
			</button>
			<button
				type="button"
				role="radio"
				aria-checked={sortDesc}
				class="grid-dir-btn"
				class:grid-dir-on={sortDesc}
				onclick={() => (sortDesc = true)}
			>
				{m.list_editor_grid_sort_desc()}
			</button>
		</div>
	</div>
</div>

<div class="cve-field">
	<div class="cve-filters-head">
		<span class="cve-field-label">{m.list_editor_filters()}</span>
		<span class="cve-field-helper">{m.list_editor_filters_helper()}</span>
	</div>
	<FilterBar {doctype} {driver} {filters} onFilterChange={(next) => (filters = next)} />
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

	.cve-field-helper {
		font-size: 11.5px;
		color: var(--text-3);
	}

	.cve-field-err {
		font-size: 11.5px;
		color: var(--danger);
	}

	.cve-filters-head,
	.cve-columns-head {
		display: flex;
		align-items: baseline;
		gap: 10px;
		flex-wrap: wrap;
	}

	.cve-filters-head {
		justify-content: space-between;
	}

	/* ── Grid settings strip ────────────────────────────────────────── */
	.grid-settings {
		display: flex;
		gap: 28px;
		flex-wrap: wrap;
		padding: 12px 14px;
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface);
	}

	.grid-setting {
		display: flex;
		flex-direction: column;
		gap: 6px;
		min-width: 200px;
	}

	.grid-frozen,
	.grid-summary {
		font: inherit;
		font-size: 12.5px;
		height: 30px;
		padding: 0 8px;
		border: 1px solid var(--border);
		border-radius: var(--r-sm, 6px);
		background: var(--surface);
		color: var(--text);
		max-width: 140px;
	}

	.grid-frozen:focus-visible,
	.grid-summary:focus-visible {
		border-color: var(--accent);
		box-shadow: 0 0 0 2px var(--accent-weak);
		outline: none;
	}

	.grid-toggle {
		display: flex;
		align-items: center;
		gap: 10px;
		min-height: 30px;
	}

	/* ── Two-pane column builder ────────────────────────────────────── */
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
		max-height: 320px;
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

	.cve-pane-sec {
		padding: 10px 12px 2px;
		font-size: 10.5px;
		font-weight: 600;
		letter-spacing: 0.06em;
		text-transform: uppercase;
		color: var(--text-3);
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

	.cve-pick-type {
		font-family: var(--font-mono);
		font-size: 10px;
		color: var(--text-3);
		border: 1px solid var(--border);
		border-radius: 4px;
		padding: 0 4px;
	}

	.cve-pick-add {
		margin-left: auto;
		color: var(--accent);
		font-weight: 600;
	}

	.cve-col-row {
		display: flex;
		align-items: flex-start;
		gap: 6px;
		padding: 6px;
		border-radius: var(--r-sm, 6px);
	}

	.cve-col-row:hover {
		background: var(--sunken);
	}

	.cve-col-controls {
		display: flex;
		flex-direction: column;
		gap: 1px;
		padding-top: 2px;
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
		gap: 4px;
		flex: 1;
		min-width: 0;
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

	.cve-col-meta {
		display: flex;
		align-items: center;
		gap: 8px;
		flex-wrap: wrap;
	}

	.cve-col-key {
		font-family: var(--font-mono);
		font-size: 11px;
		color: var(--text-3);
	}

	.cve-col-type {
		font-family: var(--font-mono);
		font-size: 10px;
		color: var(--text-3);
		border: 1px solid var(--border);
		border-radius: 4px;
		padding: 0 4px;
	}

	.cve-col-frozen {
		font-size: 10.5px;
		color: var(--accent-ink);
		background: var(--accent-weak);
		border-radius: 4px;
		padding: 0 5px;
	}

	.cve-col-note {
		font-size: 11px;
		color: var(--text-3);
	}

	.cve-col-note-warn {
		color: var(--danger);
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

	.cve-col-summary {
		display: inline-flex;
		align-items: center;
		gap: 4px;
	}

	.cve-col-summary-label {
		font-size: 11px;
		color: var(--text-3);
	}

	.cve-inline-helper {
		font-size: 11.5px;
		color: var(--text-3);
	}

	.cve-empty {
		padding: 12px 8px;
		font-size: 12px;
		color: var(--text-3);
		text-align: center;
	}

	/* ── Row sort ───────────────────────────────────────────────────── */
	.grid-sort {
		display: flex;
		align-items: flex-end;
		gap: 10px;
	}

	.grid-dir {
		display: flex;
		gap: 2px;
		padding-bottom: 1px;
	}

	.grid-dir-btn {
		height: 32px;
		padding: 0 10px;
		border: 1px solid var(--border);
		border-radius: var(--r-sm, 6px);
		background: var(--surface);
		color: var(--text-2);
		font: inherit;
		font-size: 12px;
		cursor: pointer;
	}

	.grid-dir-btn + .grid-dir-btn {
		margin-left: -1px;
		border-top-left-radius: 0;
		border-bottom-left-radius: 0;
	}

	.grid-dir-btn:first-child {
		border-top-right-radius: 0;
		border-bottom-right-radius: 0;
	}

	.grid-dir-btn.grid-dir-on {
		background: var(--accent-weak);
		border-color: var(--accent);
		color: var(--text);
	}

	.grid-dir-btn:focus-visible {
		outline: none;
		box-shadow: 0 0 0 2px var(--accent-weak);
		z-index: 1;
	}
</style>
