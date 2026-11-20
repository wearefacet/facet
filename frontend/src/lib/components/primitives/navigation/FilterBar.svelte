<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	import * as m from '$lib/paraglide/messages';
	import DropdownMenu from '$lib/components/primitives/actions/DropdownMenu.svelte';
	import type { MenuItem } from '$lib/components/primitives/actions/DropdownMenu.svelte';
	import Select from '$lib/components/primitives/forms/Select.svelte';
	import type { SelectOption } from '$lib/components/primitives/forms/Select.svelte';
	import DatetimePicker from '$lib/components/primitives/forms/DatetimePicker.svelte';
	import FilterMultiSelect from './FilterMultiSelect.svelte';
	import type { MultiOption } from './FilterMultiSelect.svelte';

	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { DataSource } from '$lib/datasource/interface.js';
	import {
		DoctypeRegistry,
		type DoctypeDefinitionRegistry
	} from '$lib/datasource/DoctypeRegistry.js';
	import type { DoctypeDef, FieldDef } from '$lib/doctype/types.js';
	import { humanize } from '$lib/doctype/types.js';
	import { fallbackCurrencyOptions, loadCurrencyOptions } from '$lib/doctype/currencies.js';
	import {
		controlKindFor,
		filterKey,
		filterableFields,
		MAX_IN_VALUES,
		operatorLabel,
		operatorsFor,
		parentFieldDef,
		SYSTEM_TIMESTAMP_FIELD_DEFS,
		type FilterControlKind,
		type FilterOperator
	} from '$lib/doctype/filters.js';

	/**
	 * Schema-aware filter bar, reusable across listing surfaces (table, calendar).
	 *
	 * Reads the doctype's `operators` metadata to render:
	 * - a free-text search box bound to the first `match`-capable field,
	 * - an "+ Add filter" menu of filterable fields (one entry per field, not per operator),
	 * - one chip per active filter. Each chip carries an operator dropdown (so the
	 *   user picks the field once, then chooses `is` / `≥` / `between` / … inline)
	 *   and a value control matched to the field type + operator.
	 *
	 * Emits `<field>__<op>=<value>` filter keys that the backend `ListRequest`
	 * and the `MockDataSource` both already understand.
	 *
	 * `between` values are emitted as `[start, end]` arrays.
	 */
	let {
		doctype,
		filters = {},
		driver,
		onFilterChange,
		showSearch = true,
		showSystemTimestamps = true
	}: {
		/** Parsed doctype definition (fields with `operators`). When undefined, nothing renders. */
		doctype?: DoctypeDef;
		/** Active filters, keyed by `field__op`. */
		filters?: Record<string, unknown>;
		/** Driver used to resolve `reference` filters. When absent, references are offered as text. */
		driver?: DataDriver;
		/** Called with the new filter map on every change. */
		onFilterChange?: (filters: Record<string, unknown>) => void;
		/** Whether to render the free-text search box. Defaults to `true`. */
		showSearch?: boolean;
		/**
		 * Whether to offer the synthesized `created_at` / `updated_at` filters.
		 * Document listings answer them through a dedicated WHERE branch; a
		 * surface whose backend drops those keys (e.g. the audit log) passes
		 * `false` so the menu never offers a filter that does nothing.
		 * Defaults to `true`.
		 */
		showSystemTimestamps?: boolean;
	} = $props();

	/**
	 * The doctype's own fields plus the synthesized virtual FieldDefs. The
	 * three are merged so that every filter primitive the bar can emit has
	 * an actual `FieldDef` for chip rendering and operator selection:
	 *
	 * - `created_at`/`updated_at` (unless suppressed) — the document-listing
	 *   backend routes them through a dedicated WHERE-clause branch rather
	 *   than the doctype `fields` schema; surfaces whose backend has no
	 *   such branch pass `showSystemTimestamps={false}`.
	 * - `parent_id` — offered only for owned-child doctypes (`member_of`
	 *   set); the backend answers the key through its parent clause, so
	 *   every other doctype simply never sees the def.
	 */
	const parentField = $derived(parentFieldDef(doctype));

	const allFields = $derived<FieldDef[]>([
		...(doctype?.fields ?? []),
		...(showSystemTimestamps ? SYSTEM_TIMESTAMP_FIELD_DEFS : []),
		...(parentField ? [parentField] : [])
	]);

	/** A filter entry joined with its parsed field/control metadata. */
	interface ActiveFilter {
		field: FieldDef;
		op: FilterOperator;
		key: string;
		control: FilterControlKind;
		value: unknown;
	}

	// ── Active filter derivation ─────────────────────────────────────────────
	const activeFilters: ActiveFilter[] = $derived.by(() => {
		const fields = allFields;
		const out: ActiveFilter[] = [];
		for (const [k, v] of Object.entries(filters)) {
			const parsed = parseFilterKey(k, fields);
			if (!parsed.field) continue;
			out.push({
				field: parsed.field,
				op: parsed.op,
				key: k,
				control: controlKindFor(parsed.field, parsed.op),
				value: v
			});
		}
		// Stable order: by field key then operator, so chips don't reshuffle on edit.
		out.sort((a, b) => a.key.localeCompare(b.key));
		return out;
	});

	function parseFilterKey(
		k: string,
		fields: FieldDef[]
	): { field: FieldDef | undefined; op: FilterOperator } {
		const idx = k.lastIndexOf('__');
		if (idx < 0) return { field: fields.find((f) => f.key === k), op: 'eq' };
		const name = k.slice(0, idx);
		const op = k.slice(idx + 2) as FilterOperator;
		return { field: fields.find((f) => f.key === name), op };
	}

	// ── Search ────────────────────────────────────────────────────────────────
	// The doctype's `search` template (rendered at mutation time into the
	// projection's `search` column) is the source of truth for the substring
	// search over the accent-folded label corpus. The filter key is the bare
	// `search` operator — `search__*` suffixed forms are not productions of
	// the filter grammar and match nothing. When no `search` template is
	// declared, the search box does not render.
	const searchable = $derived((doctype?.search?.length ?? 0) > 0);

	let searchQ = $state('');
	let lastExternalSearchQ = '';
	/** The free-text search input — focused by the `/` and `Mod+K` shortcuts. */
	let searchInput = $state<HTMLInputElement | undefined>(undefined);
	$effect(() => {
		const next = searchable && filters['search'] != null ? String(filters['search']) : '';
		// Only sync from external state when it actually changed; otherwise an
		// unrelated re-evaluation of `search` / `filters` would clobber the
		// user's in-flight input in `handleSearchInput`.
		if (next !== lastExternalSearchQ) {
			lastExternalSearchQ = next;
			searchQ = next;
		}
	});

	let searchTimer: ReturnType<typeof setTimeout> | undefined;
	function handleSearchInput(e: Event) {
		const v = (e.target as HTMLInputElement).value;
		searchQ = v;
		if (searchTimer) clearTimeout(searchTimer);
		searchTimer = setTimeout(() => {
			searchTimer = undefined;
			if (!searchable) return;
			const next = { ...filters };
			if (v.trim()) next['search'] = v.trim();
			else delete next['search'];
			onFilterChange?.(next);
		}, 250);
	}

	/**
	 * Focuses the search input (and selects its content, so typing replaces
	 * the query). Returns `false` when the doctype has no search box — the
	 * shortcut caller treats that as "not handled".
	 */
	export function focusSearch(): boolean {
		if (!searchInput) return false;
		searchInput.focus();
		searchInput.select();
		return true;
	}

	// ── Add filter menu ─────────────────────────────────────────────────────
	const addFilterItems: MenuItem[] = $derived.by(() => {
		const fields = filterableFields(allFields);
		return fields.map((f) => ({
			label: f.title ?? f.key,
			onclick: () => addFilter(f)
		}));
	});

	/**
	 * Add a chip for a field, defaulting to its first supported operator.
	 * Skips when a chip for the same field+operator already exists.
	 */
	function addFilter(field: FieldDef) {
		const ops = operatorsFor(field);
		if (ops.length === 0) return;
		const op = ops[0];
		const k = filterKey(field.key, op);
		if (filters[k] != null) return;
		const initial = initialValueFor(op);
		onFilterChange?.({ ...filters, [k]: initial });
	}

	function updateFilter(key: string, value: unknown) {
		onFilterChange?.({ ...filters, [key]: value });
	}

	/**
	 * The empty value a new chip starts with — the shape matches the
	 * operator: a bound pair for `between`, a value array for `in`, a bare
	 * string otherwise. An empty `in` array matches nothing (the backend
	 * degrades it to FALSE), mirroring the seeded `between` bounds.
	 */
	function initialValueFor(op: FilterOperator): unknown {
		if (op === 'between') return ['', ''];
		if (op === 'in') return [];
		return '';
	}

	/**
	 * Change the operator on an existing chip. Removes the old key and adds a
	 * new one with a fresh (operator-appropriate) initial value — different
	 * operators need different value shapes, so carrying the old value is
	 * rarely correct (`is: open` means nothing for `between`).
	 */
	function changeOperator(af: ActiveFilter, nextOp: FilterOperator) {
		if (nextOp === af.op) return;
		const next = { ...filters };
		delete next[af.key];
		const nextKey = filterKey(af.field.key, nextOp);
		next[nextKey] = initialValueFor(nextOp);
		onFilterChange?.(next);
	}

	function removeFilter(key: string) {
		const next = { ...filters };
		delete next[key];
		onFilterChange?.(next);
	}

	// ── Operator dropdown options per field ─────────────────────────────────
	function operatorOptions(field: FieldDef): SelectOption[] {
		return operatorsFor(field).map((op) => ({
			value: op,
			label: operatorLabel(op, field)
		}));
	}

	// ── Reference combobox (server-driven autocomplete) ────────────────────────
	// Per-filter live query/results state, keyed by the filter key.
	let refResults = $state<Record<string, SelectOption[]>>({});
	let refLoading = $state<Record<string, boolean>>({});
	// Cache of resolved label for a selected reference id, keyed by filter key.
	let refLabels = $state<Record<string, string>>({});

	function refDatasource(field: FieldDef): DataSource | undefined {
		if (!driver || !field.doctype) return undefined;
		const qualified = field.doctype;
		const sep = qualified.indexOf('.');
		const dom = sep >= 0 ? qualified.slice(0, sep) : (doctype?.domain ?? '');
		const dt = sep >= 0 ? qualified.slice(sep + 1) : qualified;
		return driver.domain(dom).doctype(dt);
	}

	// Drivers that keep no local definition store (the HTTP driver) defer to
	// the 60s-TTL `DoctypeRegistry` snapshot; one shared fetch per session.
	let registryDriver: DoctypeDefinitionRegistry | undefined;

	async function definitionFor(field: FieldDef): Promise<Record<string, unknown> | undefined> {
		if (!field.doctype || !driver) return undefined;
		const direct = driver.getDoctypeDefinition(field.doctype);
		if (direct) return direct;
		registryDriver ??= await DoctypeRegistry.cached(driver);
		return registryDriver.getDoctypeDefinition(field.doctype);
	}

	async function refDisplayField(field: FieldDef): Promise<string> {
		const def = await definitionFor(field);
		const fields = def?.['fields'] as Record<string, Record<string, unknown>> | undefined;
		if (fields) {
			for (const [k, f] of Object.entries(fields)) {
				if (f['type'] === 'string' || f['type'] === 'longtext') return k;
			}
		}
		return 'id';
	}

	/** The row's human label: backend-computed `display_name` first, then the doctype's first string field, then the id. */
	function refLabel(
		item: { meta: { id: string; display_name?: string | null }; data: Record<string, unknown> },
		displayField: string
	): string {
		return item.meta.display_name || String(item.data?.[displayField] ?? item.meta.id);
	}

	/**
	 * Strips the anchored `{domain}.{Doctype}.` prefix from a qualified
	 * reference value. The backend `id` system filter compares bare stored
	 * ids — a qualified token would miss and degrade the label to the raw
	 * id (the same strip the backend `Document::ReferenceCheck` applies;
	 * the target doctype is known from the field def, so it is unambiguous).
	 */
	function stripTargetPrefix(id: string, field: FieldDef): string {
		const prefix = field.doctype ? `${field.doctype}.` : '';
		return prefix && id.startsWith(prefix) ? id.slice(prefix.length) : id;
	}

	async function runRefSearch(field: FieldDef, fk: string, q: string) {
		const ds = refDatasource(field);
		if (!ds) return;
		refLoading[fk] = true;
		try {
			const displayField = await refDisplayField(field);
			const res = await ds.list(
				q ? { items: 25, filters: { [`${displayField}__match`]: q } } : { items: 25 }
			);
			refResults[fk] = res.data.map((item) => {
				const row = item as {
					meta: { id: string; display_name?: string | null };
					data: Record<string, unknown>;
				};
				return {
					value: row.meta.id,
					label: refLabel(row, displayField)
				};
			});
		} finally {
			refLoading[fk] = false;
		}
	}

	// Resolve the label for an already-selected reference whenever the value changes.
	$effect(() => {
		for (const af of activeFilters) {
			if (af.control !== 'reference') continue;
			const id = af.value as string;
			if (!id) {
				delete refLabels[af.key];
				continue;
			}
			// Skip if we already have it cached.
			if (refLabels[af.key] === id) continue;
			resolveRefLabel(af.field, af.key, id);
		}
	});

	async function resolveRefLabel(field: FieldDef, fk: string, id: string) {
		const ds = refDatasource(field);
		if (!ds) {
			refLabels[fk] = id;
			return;
		}
		try {
			const displayField = await refDisplayField(field);
			const res = await ds.list({ items: 1, filters: { id__eq: stripTargetPrefix(id, field) } });
			const item = res.data[0] as
				| { meta: { id: string; display_name?: string | null }; data: Record<string, unknown> }
				| undefined;
			refLabels[fk] = item ? refLabel(item, displayField) : id;
		} catch {
			refLabels[fk] = id;
		}
	}

	let refTimer: ReturnType<typeof setTimeout> | undefined;
	function onRefInput(field: FieldDef, fk: string, q: string) {
		if (refTimer) clearTimeout(refTimer);
		refTimer = setTimeout(() => {
			refTimer = undefined;
			runRefSearch(field, fk, q);
		}, 250);
	}

	function onRefSelect(fk: string, id: string) {
		const hit = (refResults[fk] ?? []).find(
			(o): o is Extract<SelectOption, { value: string }> => 'value' in o && o.value === id
		);
		refLabels[fk] = hit?.label ?? id;
		updateFilter(fk, id);
	}

	// ── Between (range) value helpers ────────────────────────────────────────
	function betweenValue(af: ActiveFilter): [string, string] {
		const v = af.value;
		if (Array.isArray(v) && v.length === 2) return [String(v[0] ?? ''), String(v[1] ?? '')];
		return ['', ''];
	}

	/** The `in` chip's selected values, normalized to a string array. */
	function multiValue(af: ActiveFilter): string[] {
		const v = af.value;
		return Array.isArray(v) ? v.map((x) => String(x)) : [];
	}

	function updateBetweenBound(af: ActiveFilter, idx: 0 | 1, raw: string) {
		const [lo, hi] = betweenValue(af);
		const next = idx === 0 ? [raw, hi] : [lo, raw];
		updateFilter(af.key, next);
	}

	// ── Helpers for rendering ────────────────────────────────────────────────
	function enumOptions(field: FieldDef): MultiOption[] {
		return (field.values ?? []).map((v) => ({ value: v.key, label: v.label ?? humanize(v.key) }));
	}

	/** The boolean chip's fixed options. Values are the wire strings the backend parses. */
	function booleanOptions(): SelectOption[] {
		return [
			{ value: 'true', label: m.list_filter_true() },
			{ value: 'false', label: m.list_filter_false() }
		];
	}

	// ── Currency picker (money `__currency` chips) ────────────────────────
	// Options come from the `core.Currency` registry (active rows, favorites
	// first) when a driver can reach it; the static fallback list covers
	// storybook and offline surfaces. Loaded once, lazily, when the first
	// currency chip renders.
	let currencyOptions = $state<SelectOption[]>(fallbackCurrencyOptions());
	let currencyOptionsLoaded = false;

	$effect(() => {
		if (currencyOptionsLoaded) return;
		if (!activeFilters.some((af) => af.control === 'currency')) return;
		currencyOptionsLoaded = true;
		loadCurrencyOptions(driver).then((opts) => (currencyOptions = opts));
	});

	function chipLabel(af: ActiveFilter): string {
		return af.field.title ?? af.field.key;
	}

	function displayValue(af: ActiveFilter): string {
		return af.value == null ? '' : String(af.value);
	}
</script>

{#if doctype}
	<div class="fbar">
		{#if showSearch && searchable}
			<div class="search">
				<svg
					width="15"
					height="15"
					fill="none"
					stroke="currentColor"
					stroke-width="2"
					viewBox="0 0 24 24"
					aria-hidden="true"
				>
					<circle cx="11" cy="11" r="7" />
					<path d="m21 21-4-4" />
				</svg>
				<input
					bind:this={searchInput}
					placeholder={m.list_search_placeholder()}
					value={searchQ}
					oninput={handleSearchInput}
				/>
			</div>
		{/if}

		{#each activeFilters as af (af.key)}
			<div class="chip act">
				<span class="chip-label">{chipLabel(af)}</span>
				<div class="chip-op">
					<Select
						placeholder="—"
						options={operatorOptions(af.field)}
						value={af.op}
						onValueChange={(v) => changeOperator(af, v as FilterOperator)}
					/>
				</div>

				{#if af.control === 'enum-multi'}
					<FilterMultiSelect
						options={enumOptions(af.field)}
						selected={multiValue(af)}
						max={MAX_IN_VALUES}
						ariaLabel={m.list_filter_values_aria({ field: chipLabel(af) })}
						onchange={(next) => updateFilter(af.key, next)}
					/>
				{:else if af.control === 'enum'}
					<Select
						placeholder="—"
						options={enumOptions(af.field)}
						value={(af.value as string) ?? ''}
						onValueChange={(v) => updateFilter(af.key, v)}
					/>
				{:else if af.control === 'boolean'}
					<Select
						placeholder="—"
						options={booleanOptions()}
						value={displayValue(af)}
						onValueChange={(v) => updateFilter(af.key, v)}
					/>
				{:else if af.control === 'currency'}
					<Select
						placeholder="—"
						options={currencyOptions}
						value={displayValue(af)}
						onValueChange={(v) => updateFilter(af.key, v)}
					/>
				{:else if af.control === 'reference'}
					<Select
						placeholder={m.list_filter_pick_placeholder()}
						value={String(af.value ?? '')}
						results={refResults[af.key] ?? []}
						loading={refLoading[af.key] ?? false}
						onsearch={(q) => onRefInput(af.field, af.key, q)}
						onValueChange={(v) => onRefSelect(af.key, v)}
					/>
				{:else if af.control === 'number' && af.op === 'between'}
					<input
						class="chip-input chip-input-num"
						type="number"
						placeholder={m.list_filter_min()}
						value={betweenValue(af)[0]}
						oninput={(e) => updateBetweenBound(af, 0, (e.target as HTMLInputElement).value)}
					/>
					<span class="chip-sep">–</span>
					<input
						class="chip-input chip-input-num"
						type="number"
						placeholder={m.list_filter_max()}
						value={betweenValue(af)[1]}
						oninput={(e) => updateBetweenBound(af, 1, (e.target as HTMLInputElement).value)}
					/>
				{:else if af.control === 'datetime' && af.op === 'between'}
					<DatetimePicker
						compact
						label={m.list_filter_from()}
						value={betweenValue(af)[0]}
						onchange={(iso) => updateBetweenBound(af, 0, iso)}
					/>
					<span class="chip-sep">–</span>
					<DatetimePicker
						compact
						label={m.list_filter_to()}
						value={betweenValue(af)[1]}
						onchange={(iso) => updateBetweenBound(af, 1, iso)}
					/>
				{:else if af.control === 'number'}
					<input
						class="chip-input chip-input-num"
						type="number"
						aria-label={m.list_filter_value_aria({
							field: chipLabel(af),
							op: operatorLabel(af.op, af.field)
						})}
						value={displayValue(af)}
						oninput={(e) => updateFilter(af.key, (e.target as HTMLInputElement).value)}
					/>
				{:else if af.control === 'datetime'}
					<DatetimePicker
						compact
						label={chipLabel(af)}
						value={displayValue(af)}
						onchange={(iso) => updateFilter(af.key, iso)}
					/>
				{:else}
					<input
						class="chip-input"
						aria-label={m.list_filter_value_aria({
							field: chipLabel(af),
							op: operatorLabel(af.op, af.field)
						})}
						value={displayValue(af)}
						oninput={(e) => updateFilter(af.key, (e.target as HTMLInputElement).value)}
					/>
				{/if}
				<button
					class="x"
					aria-label={m.list_filter_remove_aria()}
					onclick={() => removeFilter(af.key)}>✕</button
				>
			</div>
		{/each}

		{#if addFilterItems.length > 0}
			<DropdownMenu label={m.list_filter_add()} items={addFilterItems} />
		{/if}
	</div>
{/if}

<style>
	.fbar {
		display: flex;
		align-items: center;
		gap: 8px;
		flex-wrap: wrap;
		padding: 10px 14px;
		border-bottom: 1px solid var(--border);
		background: var(--surface);
	}

	.search {
		display: flex;
		align-items: center;
		gap: 8px;
		padding: 6px 10px;
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface-2);
		color: var(--text-3);
		min-width: 220px;
	}

	.search:hover {
		border-color: var(--border-strong);
	}

	.search input {
		border: none;
		background: none;
		outline: none;
		font: inherit;
		color: var(--text);
		width: 100%;
	}

	.search input::placeholder {
		color: var(--text-3);
	}

	.chip.act {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		padding: 4px 8px;
		border: 1px solid var(--border-strong);
		border-radius: var(--r-pill);
		background: var(--surface-2);
		font-size: 12.5px;
		color: var(--text-2);
	}

	.chip-label {
		color: var(--text-3);
	}

	.chip-sep {
		color: var(--text-3);
		font-size: 11px;
	}

	.chip-input {
		border: none;
		background: none;
		outline: none;
		font: inherit;
		font-size: 12.5px;
		color: var(--text);
		width: 140px;
		padding: 0;
	}

	.chip-input-num {
		width: 70px;
	}

	.chip-input:focus {
		outline: 1px solid var(--accent);
		border-radius: var(--r-sm);
	}

	/* ── Form control overrides inside chips ──────────────────────────────── */
	/* Select and Search render their own wraps; shrink them to chip scale. */
	:global(.chip.act .select-wrap) {
		gap: 0;
	}

	:global(.chip.act .select-field-wrap) {
		padding: 0 18px 0 0;
		border: none;
		background: none;
		font-size: 12.5px;
		min-height: 0;
	}

	:global(.chip.act .autocomplete-wrap) {
		gap: 0;
	}

	:global(.chip.act .autocomplete-field-wrap) {
		position: relative;
	}

	:global(.chip.act .autocomplete-field) {
		padding: 0;
		border: none;
		background: none;
		font-size: 12.5px;
		width: 140px;
	}

	:global(.chip.act .autocomplete-spinner) {
		right: -14px;
	}

	.x {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: 16px;
		height: 16px;
		border: none;
		background: none;
		color: var(--text-3);
		cursor: pointer;
		font-size: 11px;
		padding: 0;
		border-radius: var(--r-sm);
	}

	.x:hover {
		color: var(--danger);
		background: var(--danger-weak);
	}
</style>
