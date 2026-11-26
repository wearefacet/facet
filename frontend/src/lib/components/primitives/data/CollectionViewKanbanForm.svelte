<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { DoctypeDef, FieldDef } from '$lib/doctype/types.js';
	import Select from '$lib/components/primitives/forms/Select.svelte';
	import Input from '$lib/components/primitives/forms/Input.svelte';
	import DatetimePicker from '$lib/components/primitives/forms/DatetimePicker.svelte';
	import ReferencePicker from '$lib/components/primitives/forms/ReferencePicker.svelte';
	import FilterBar from '$lib/components/primitives/navigation/FilterBar.svelte';
	import Button from '$lib/components/primitives/actions/Button.svelte';
	import Toggle from '$lib/components/primitives/forms/Toggle.svelte';
	import {
		controlKindFor,
		filterableFields,
		operatorLabel,
		operatorsFor,
		type FilterControlKind,
		type FilterOperator
	} from '$lib/doctype/filters.js';
	import { fallbackCurrencyOptions, loadCurrencyOptions } from '$lib/doctype/currencies.js';
	import { fieldOptions, groupableFields, sortableFields } from '$lib/collectionView/config.js';
	import type { KanbanLane } from '$lib/collectionView/types.js';
	import {
		applyLaneOverrides,
		groupByLaneKeys,
		laneKey,
		lanesFromGroupBy
	} from '$lib/kanban/lanes.js';

	/**
	 * Kanban-surface configuration form — board mode (values vs custom), the
	 * group-by picker, the values-mode lane list (per-lane visibility toggle
	 * and reorder buttons), the ordered custom-lane editor, the card sort
	 * picker, the drag-and-drop move toggle, and the embedded FilterBar. The
	 * kanban values live in the parent; each bindable prop round-trips the
	 * writes so the parent keeps its one-time-initialised draft state.
	 *
	 * A custom lane's filter is rebuilt from the field / operator / value
	 * trio on every change and omitted while the trio is incomplete, so an
	 * incomplete lane surfaces the lane's "empty filter" validation error.
	 */
	let {
		doctype,
		driver,
		kanbanMode = $bindable('values'),
		groupBy = $bindable(''),
		/** Values mode: the authored lane order — the value keys, display order. */
		laneOrder = $bindable<string[]>([]),
		/** Values mode: the hidden lane keys (the values not shown). */
		hiddenLanes = $bindable<string[]>([]),
		/** Custom mode: ordered lane list. */
		lanes = $bindable<KanbanLane[]>([]),
		sortField = $bindable(''),
		sortDesc = $bindable(true),
		/** Drag & drop moves between lanes enabled. */
		allowMove = $bindable(false),
		filters = $bindable<Record<string, unknown>>({}),
		groupByError = null,
		lanesError = null,
		laneErrors = [],
		onGroupByBlur
	}: {
		/** Parsed parent doctype definition (pickers and FilterBar read its fields). */
		doctype: DoctypeDef;
		/** Driver used by the FilterBar to resolve `reference` filters. */
		driver: DataDriver;
		/** Lane derivation mode. */
		kanbanMode?: 'values' | 'custom';
		/** Values mode: the enum field key whose values become lanes. */
		groupBy?: string;
		/** Values mode: the authored lane order — the value keys, display order. */
		laneOrder?: string[];
		/** Values mode: the hidden lane keys (the values not shown). */
		hiddenLanes?: string[];
		/** Custom mode: ordered lane list. */
		lanes?: KanbanLane[];
		/** Card sort field; empty means the surface default. */
		sortField?: string;
		/** Card sort direction (descending when true — the `-` prefix). */
		sortDesc?: boolean;
		/** Drag & drop moves between lanes enabled. */
		allowMove?: boolean;
		/** Fields the FilterBar may filter on — stale keys drop against it. */
		filterableFields: FieldDef[];
		/** Active base filters, keyed by `field__op`. */
		filters?: Record<string, unknown>;
		/** Set when values mode requires the group-by field. */
		groupByError?: string | null;
		/** Set when custom mode has no lane at all. */
		lanesError?: string | null;
		/** Per-lane validation errors, by lane index. */
		laneErrors?: { index: number; error: string }[];
		/** Reports a blur of the group-by picker (reveals the required hint). */
		onGroupByBlur?: () => void;
	} = $props();

	// ── Option lists ─────────────────────────────────────────────────
	const groupableOptions = $derived(fieldOptions(groupableFields(doctype.fields)));
	const laneFieldDefs = $derived(filterableFields(doctype.fields));
	const laneFieldOptions = $derived(fieldOptions(laneFieldDefs));
	const sortOptions = $derived(fieldOptions(sortableFields(doctype.fields)));

	// ── Values-mode lane list ─────────────────────────────────────────
	/** One row of the values-mode lane list — the derived lane plus the
	 *  pieces the row's controls read and write. */
	interface ValueLaneRow {
		/** The lane key — the group-by value the lane matches. */
		key: string;
		/** The derived lane (label, colour, filter). */
		lane: KanbanLane;
		/** Whether the lane stays on the board. */
		visible: boolean;
	}

	const groupByFieldDef = $derived(doctype.fields.find((f) => f.key === groupBy.trim()));
	const derivedLanes = $derived(groupByFieldDef ? lanesFromGroupBy(groupByFieldDef) : []);
	/** The full row list in authored order — hidden lanes stay listed (with
	 *  the toggle off) so they can be re-enabled. */
	const valueLanes = $derived.by<ValueLaneRow[]>(() => {
		if (!groupByFieldDef) return [];
		const ordered = applyLaneOverrides(derivedLanes, laneOrder, undefined);
		return ordered.map((lane) => {
			const key = laneKey(lane) ?? '';
			return { key, lane, visible: !hiddenLanes.includes(key) };
		});
	});

	/** Group-by change — the lane order and visibility belong to the previous
	 *  field's values, so both reset to the new field's declaration order. */
	function onGroupByChange(key: string): void {
		groupBy = key;
		const field = doctype.fields.find((f) => f.key === key.trim());
		laneOrder = field ? groupByLaneKeys(field) : [];
		hiddenLanes = [];
	}

	function toggleValueLane(key: string, visible: boolean): void {
		hiddenLanes = visible
			? hiddenLanes.filter((k) => k !== key)
			: hiddenLanes.includes(key)
				? hiddenLanes
				: [...hiddenLanes, key];
	}

	function moveValueLane(key: string, dir: -1 | 1): void {
		const keys = valueLanes.map((row) => row.key);
		const index = keys.indexOf(key);
		const target = index + dir;
		if (index < 0 || target < 0 || target >= keys.length) return;
		[keys[index], keys[target]] = [keys[target], keys[index]];
		laneOrder = keys;
	}

	// ── Lane editor ──────────────────────────────────────────────────────
	/** Per-lane editing shape, parsed from the lane filter for the controls. */
	interface LaneTrio {
		field: FieldDef | undefined;
		op: FilterOperator | '';
		value: unknown;
	}

	function parseLane(lane: KanbanLane): LaneTrio {
		const entries = Object.entries(lane.filter);
		if (entries.length !== 1) return { field: undefined, op: '', value: '' };
		const [key, value] = entries[0];
		const idx = key.lastIndexOf('__');
		if (idx < 0) return { field: undefined, op: '', value: '' };
		const fieldKey = key.slice(0, idx);
		const op = key.slice(idx + 2) as FilterOperator;
		return { field: laneFieldDefs.find((f) => f.key === fieldKey), op, value };
	}

	/** Rebuild the lane filter from the trio. The `field__op` key stays in
	 *  place once the field and operator are chosen (even while the value is
	 *  still blank) so the controls keep their selection; `validateLanes`
	 *  treats a blank value as an empty filter. */
	function trioFilter(
		fieldKey: string,
		op: FilterOperator | '',
		value: unknown
	): Record<string, unknown> {
		if (fieldKey.length === 0 || op === '') return {};
		return { [`${fieldKey}__${op}`]: value };
	}

	function patchLane(index: number, patch: Partial<KanbanLane>): void {
		// Replace the array entry — shared proxy objects must not mutate.
		lanes = lanes.map((lane, i) => (i === index ? { ...lane, ...patch } : lane));
	}

	function patchLaneTrio(index: number, trio: LaneTrio): void {
		patchLane(index, {
			filter: trioFilter(trio.field?.key ?? '', trio.op, trio.value)
		});
	}

	function addLane(): void {
		lanes = [...lanes, { label: '', filter: {} }];
	}

	function removeLane(index: number): void {
		lanes = lanes.filter((_, i) => i !== index);
	}

	function moveLane(index: number, dir: -1 | 1): void {
		const target = index + dir;
		if (target < 0 || target >= lanes.length) return;
		const next = [...lanes];
		[next[index], next[target]] = [next[target], next[index]];
		lanes = next;
	}

	function laneError(index: number): string | null {
		return laneErrors.find((e) => e.index === index)?.error ?? null;
	}

	function operatorOptions(field: FieldDef): { value: FilterOperator; label: string }[] {
		// Lanes are point filters (one lane = one value); the multi-value `in`
		// operator has no lane value control, so it stays out of the pickers
		// (the FilterBar chip is the only `in` surface).
		return operatorsFor(field)
			.filter((op) => op !== 'in')
			.map((op) => ({ value: op, label: operatorLabel(op, field) }));
	}

	function laneValueText(trio: LaneTrio): string {
		return trio.value == null || Array.isArray(trio.value) ? '' : String(trio.value);
	}

	// ── Currency control (money lanes on the `currency` operator) ────────
	// Options load from the `core.Currency` registry through the driver,
	// with the static fallback when it cannot be reached. Loaded lazily
	// when the first currency lane control renders.
	let currencyOptions = $state(fallbackCurrencyOptions());
	let currencyOptionsLoaded = false;

	$effect(() => {
		if (currencyOptionsLoaded) return;
		const needs = lanes.some((lane) => {
			const trio = parseLane(lane);
			if (!trio.field) return false;
			return controlKindFor(trio.field, (trio.op || 'eq') as FilterOperator) === 'currency';
		});
		if (!needs) return;
		currencyOptionsLoaded = true;
		loadCurrencyOptions(driver).then((opts) => (currencyOptions = opts));
	});
</script>

<div class="cve-field">
	<span class="cve-field-label">{m.list_editor_kanban_mode()}</span>
	<div class="kb-mode" role="radiogroup" aria-label={m.list_editor_kanban_mode()}>
		<button
			type="button"
			role="radio"
			aria-checked={kanbanMode === 'values'}
			class="kb-mode-btn"
			class:kb-mode-on={kanbanMode === 'values'}
			onclick={() => (kanbanMode = 'values')}
		>
			<span>{m.list_editor_kanban_mode_values()}</span>
			<span class="kb-mode-desc">{m.list_editor_kanban_mode_values_desc()}</span>
		</button>
		<button
			type="button"
			role="radio"
			aria-checked={kanbanMode === 'custom'}
			class="kb-mode-btn"
			class:kb-mode-on={kanbanMode === 'custom'}
			onclick={() => (kanbanMode = 'custom')}
		>
			<span>{m.list_editor_kanban_mode_custom()}</span>
			<span class="kb-mode-desc">{m.list_editor_kanban_mode_custom_desc()}</span>
		</button>
	</div>
</div>

{#if kanbanMode === 'values'}
	<div class="cve-field">
		<Select
			label={m.list_editor_group_by_label()}
			placeholder={m.list_editor_group_by_placeholder()}
			options={groupableOptions}
			value={groupBy}
			searchable={false}
			onValueChange={(key) => onGroupByChange(key)}
			onblur={() => onGroupByBlur?.()}
			error={groupByError ?? undefined}
		/>
		<span class="cve-field-helper">{m.list_editor_group_by_helper()}</span>
	</div>
	{#if valueLanes.length > 0}
		<div class="cve-field">
			<div class="cve-filters-head">
				<span class="cve-field-label">{m.list_editor_lanes_label()}</span>
				<span class="cve-field-helper">{m.list_editor_kanban_lanes_helper()}</span>
			</div>
			{#if lanesError}<span class="kb-lane-error" role="alert">{lanesError}</span>{/if}
			{#each valueLanes as vl, i (vl.key)}
				<div class="kb-vlane" class:kb-vlane-hidden={!vl.visible}>
					<span
						class="kb-vlane-dot"
						style={`background: ${vl.lane.color ?? 'var(--text-3)'};`}
						aria-hidden="true"
					></span>
					<span class="kb-vlane-label">{vl.lane.label}</span>
					<div class="kb-lane-actions">
						<button
							type="button"
							class="kb-lane-btn"
							aria-label={m.list_editor_move_up_aria()}
							disabled={i === 0}
							onclick={() => moveValueLane(vl.key, -1)}
						>
							↑
						</button>
						<button
							type="button"
							class="kb-lane-btn"
							aria-label={m.list_editor_move_down_aria()}
							disabled={i === valueLanes.length - 1}
							onclick={() => moveValueLane(vl.key, 1)}
						>
							↓
						</button>
						<Toggle
							checked={vl.visible}
							aria-label={m.list_editor_lane_visibility_aria({ lane: i + 1 })}
							onchange={(checked) => toggleValueLane(vl.key, checked)}
						/>
					</div>
				</div>
			{/each}
		</div>
	{/if}
{:else}
	<div class="cve-field">
		<div class="cve-filters-head">
			<span class="cve-field-label">{m.list_editor_lanes_label()}</span>
			{#if lanesError}<span class="kb-lane-error" role="alert">{lanesError}</span>{/if}
		</div>
		{#each lanes as lane, i (i)}
			{@const trio = parseLane(lane)}
			<div class="kb-lane">
				<div class="kb-lane-row">
					<Input
						label={m.list_editor_lane_label({ lane: i + 1 })}
						value={lane.label}
						oninput={(e) => patchLane(i, { label: (e.target as HTMLInputElement).value })}
					/>
					<Select
						label={m.list_editor_lane_field({ lane: i + 1 })}
						placeholder={m.list_editor_group_by_placeholder()}
						options={laneFieldOptions}
						value={trio.field?.key ?? ''}
						searchable={false}
						onValueChange={(key) => {
							const next = laneFieldDefs.find((f) => f.key === key);
							const ops = next ? operatorsFor(next) : [];
							patchLaneTrio(i, { field: next, op: ops[0] ?? '', value: '' });
						}}
					/>
					{#if trio.field}
						<Select
							label={m.list_editor_lane_operator({ lane: i + 1 })}
							options={operatorOptions(trio.field)}
							value={trio.op || operatorsFor(trio.field)[0]}
							searchable={false}
							onValueChange={(op) =>
								patchLaneTrio(i, { ...trio, op: op as FilterOperator, value: '' })}
						/>
						{@const kind = controlKindFor(
							trio.field,
							(trio.op || 'eq') as FilterOperator
						) as FilterControlKind}
						{#if trio.op === 'between' && kind === 'number'}
							<div class="kb-lane-between">
								<Input
									type="number"
									label={m.list_filter_from()}
									value={Array.isArray(trio.value)
										? laneValueText({ ...trio, value: trio.value[0] })
										: ''}
									oninput={(e) =>
										patchLaneTrio(i, {
											...trio,
											value: [
												(e.target as HTMLInputElement).value,
												Array.isArray(trio.value) ? trio.value[1] : ''
											]
										})}
								/>
								<Input
									type="number"
									label={m.list_filter_to()}
									value={Array.isArray(trio.value)
										? laneValueText({ ...trio, value: trio.value[1] })
										: ''}
									oninput={(e) =>
										patchLaneTrio(i, {
											...trio,
											value: [
												Array.isArray(trio.value) ? trio.value[0] : '',
												(e.target as HTMLInputElement).value
											]
										})}
								/>
							</div>
						{:else if trio.op === 'between' && kind === 'datetime'}
							<div class="kb-lane-between">
								<DatetimePicker
									compact
									label={m.list_filter_from()}
									value={Array.isArray(trio.value) ? String(trio.value[0] ?? '') : ''}
									onchange={(iso) =>
										patchLaneTrio(i, {
											...trio,
											value: [iso, Array.isArray(trio.value) ? trio.value[1] : '']
										})}
								/>
								<DatetimePicker
									compact
									label={m.list_filter_to()}
									value={Array.isArray(trio.value) ? String(trio.value[1] ?? '') : ''}
									onchange={(iso) =>
										patchLaneTrio(i, {
											...trio,
											value: [Array.isArray(trio.value) ? trio.value[0] : '', iso]
										})}
								/>
							</div>
						{:else if kind === 'enum'}
							<Select
								label={m.list_editor_lane_value({ lane: i + 1 })}
								placeholder={m.list_filter_pick_placeholder()}
								options={(trio.field.values ?? []).map((v) => ({
									value: v.key,
									label: v.label ?? v.key
								}))}
								value={laneValueText(trio)}
								searchable={false}
								onValueChange={(v) => patchLaneTrio(i, { ...trio, value: v })}
							/>
						{:else if kind === 'boolean'}
							<Select
								label={m.list_editor_lane_value({ lane: i + 1 })}
								placeholder={m.list_filter_pick_placeholder()}
								options={[
									{ value: 'true', label: m.list_filter_true() },
									{ value: 'false', label: m.list_filter_false() }
								]}
								value={laneValueText(trio)}
								searchable={false}
								onValueChange={(v) => patchLaneTrio(i, { ...trio, value: v })}
							/>
						{:else if kind === 'currency'}
							<Select
								label={m.list_editor_lane_value({ lane: i + 1 })}
								placeholder={m.list_filter_pick_placeholder()}
								options={currencyOptions}
								value={laneValueText(trio)}
								onValueChange={(v) => patchLaneTrio(i, { ...trio, value: v })}
							/>
						{:else if kind === 'reference'}
							<ReferencePicker
								label={m.list_editor_lane_value({ lane: i + 1 })}
								doctype={trio.field.doctype}
								filter={trio.field.filter}
								{driver}
								bind:value={
									() => laneValueText(trio),
									(v) => {
										if (v !== laneValueText(trio)) patchLaneTrio(i, { ...trio, value: v });
									}
								}
							/>
						{:else if kind === 'number'}
							<Input
								type="number"
								label={m.list_editor_lane_value({ lane: i + 1 })}
								value={laneValueText(trio)}
								oninput={(e) =>
									patchLaneTrio(i, { ...trio, value: (e.target as HTMLInputElement).value })}
							/>
						{:else if kind === 'datetime'}
							<DatetimePicker
								compact
								label={m.list_editor_lane_value({ lane: i + 1 })}
								value={laneValueText(trio)}
								onchange={(iso) => patchLaneTrio(i, { ...trio, value: iso })}
							/>
						{:else}
							<Input
								label={m.list_editor_lane_value({ lane: i + 1 })}
								value={laneValueText(trio)}
								oninput={(e) =>
									patchLaneTrio(i, { ...trio, value: (e.target as HTMLInputElement).value })}
							/>
						{/if}
					{/if}
					<div class="kb-lane-actions">
						<button
							type="button"
							class="kb-lane-btn"
							aria-label={m.list_editor_move_up_aria()}
							disabled={i === 0}
							onclick={() => moveLane(i, -1)}
						>
							↑
						</button>
						<button
							type="button"
							class="kb-lane-btn"
							aria-label={m.list_editor_move_down_aria()}
							disabled={i === lanes.length - 1}
							onclick={() => moveLane(i, 1)}
						>
							↓
						</button>
						<button
							type="button"
							class="kb-lane-btn kb-lane-remove"
							aria-label={m.list_editor_lane_remove_aria({ lane: i + 1 })}
							onclick={() => removeLane(i)}
						>
							✕
						</button>
					</div>
				</div>
				{#if laneError(i)}
					<span class="kb-lane-error" role="alert">{laneError(i)}</span>
				{/if}
			</div>
		{/each}
		<Button variant="secondary" onclick={addLane}>{m.list_editor_lane_add()}</Button>
	</div>
{/if}

<div class="cve-field">
	<div class="cve-filters-head">
		<span class="cve-field-label">{m.list_editor_kanban_allow_move()}</span>
		<span class="cve-field-helper">{m.list_editor_kanban_allow_move_helper()}</span>
	</div>
	<Toggle
		checked={allowMove}
		aria-label={m.list_editor_kanban_allow_move()}
		onchange={(checked) => (allowMove = checked)}
	/>
</div>

<div class="cve-field">
	<div class="cve-filters-head">
		<span class="cve-field-label">{m.list_editor_kanban_sort()}</span>
		<span class="cve-field-helper">{m.list_editor_kanban_sort_helper()}</span>
	</div>
	<div class="kb-sort">
		<Select
			label={m.list_editor_kanban_sort()}
			placeholder={m.list_editor_kanban_sort_default()}
			options={sortOptions}
			bind:value={sortField}
		/>
		<div class="kb-dir" role="radiogroup" aria-label={m.list_editor_kanban_sort_dir_aria()}>
			<button
				type="button"
				role="radio"
				aria-checked={!sortDesc}
				class="kb-dir-btn"
				class:kb-dir-on={!sortDesc}
				onclick={() => (sortDesc = false)}
			>
				{m.list_editor_kanban_sort_asc()}
			</button>
			<button
				type="button"
				role="radio"
				aria-checked={sortDesc}
				class="kb-dir-btn"
				class:kb-dir-on={sortDesc}
				onclick={() => (sortDesc = true)}
			>
				{m.list_editor_kanban_sort_desc()}
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

	.cve-filters-head {
		display: flex;
		align-items: baseline;
		justify-content: space-between;
		gap: 10px;
		flex-wrap: wrap;
	}

	.kb-mode {
		display: grid;
		grid-template-columns: 1fr 1fr;
		gap: 10px;
	}

	.kb-mode-btn {
		display: flex;
		flex-direction: column;
		gap: 4px;
		padding: 12px;
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface);
		color: var(--text);
		text-align: left;
		font: inherit;
		font-weight: 600;
		font-size: 13px;
		cursor: pointer;
		transition:
			border-color 0.12s,
			box-shadow 0.12s;
	}

	.kb-mode-btn:hover {
		border-color: var(--border-strong);
	}

	.kb-mode-on {
		border-color: var(--accent);
		box-shadow: 0 0 0 3px var(--accent-weak);
	}

	.kb-mode-btn:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 1px;
	}

	.kb-mode-desc {
		font-weight: 400;
		font-size: 11.5px;
		color: var(--text-3);
	}

	.kb-lane {
		display: flex;
		flex-direction: column;
		gap: 4px;
		padding: 10px;
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface);
	}

	.kb-vlane {
		display: flex;
		align-items: center;
		gap: 9px;
		padding: 7px 2px;
		border-bottom: 1px solid var(--border);
	}

	.kb-vlane:last-child {
		border-bottom: none;
	}

	.kb-vlane-hidden .kb-vlane-label,
	.kb-vlane-hidden .kb-vlane-dot {
		opacity: 0.45;
	}

	.kb-vlane-dot {
		width: 8px;
		height: 8px;
		border-radius: 2px;
		transform: rotate(45deg);
		flex-shrink: 0;
	}

	.kb-vlane-label {
		flex: 1;
		min-width: 0;
		overflow: hidden;
		text-overflow: ellipsis;
		white-space: nowrap;
		font-size: 13px;
		color: var(--text);
	}

	.kb-lane-row {
		display: grid;
		grid-template-columns: 1.2fr 1fr 0.7fr 1fr auto;
		gap: 8px;
		align-items: end;
	}

	.kb-lane-between {
		display: flex;
		flex-direction: column;
		gap: 6px;
	}

	.kb-lane-actions {
		display: flex;
		gap: 4px;
	}

	.kb-lane-btn {
		width: 26px;
		height: 30px;
		display: inline-flex;
		align-items: center;
		justify-content: center;
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface);
		color: var(--text-2);
		font-size: 12px;
		cursor: pointer;
		transition:
			color 0.12s,
			border-color 0.12s;
	}

	.kb-lane-btn:hover:not(:disabled) {
		color: var(--text);
		border-color: var(--border-strong);
	}

	.kb-lane-btn:disabled {
		opacity: 0.4;
		cursor: not-allowed;
	}

	.kb-lane-btn:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 1px;
	}

	.kb-lane-remove:hover {
		color: var(--danger);
		border-color: var(--danger);
	}

	.kb-lane-error {
		font-size: 11.5px;
		color: var(--danger);
	}

	.kb-sort {
		display: grid;
		grid-template-columns: 1.4fr auto;
		gap: 8px;
		align-items: end;
	}

	.kb-dir {
		display: flex;
		border: 1px solid var(--border);
		border-radius: var(--r);
		overflow: hidden;
		font-size: 12px;
	}

	.kb-dir-btn {
		padding: 8px 12px;
		background: var(--surface);
		color: var(--text-2);
		border: none;
		cursor: pointer;
		font: inherit;
	}

	.kb-dir-btn + .kb-dir-btn {
		border-left: 1px solid var(--border);
	}

	.kb-dir-btn.kb-dir-on {
		background: var(--surface-2);
		color: var(--accent-ink);
		font-weight: 600;
	}

	.kb-dir-btn:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: -2px;
	}
</style>
