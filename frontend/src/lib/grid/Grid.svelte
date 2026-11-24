<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	The grid listing surface (`surface: grid`) — the listing as a spreadsheet.

	One row per document, one column per field, no free cells. The component
	mirrors the `Table`'s data machinery (toolbar, capped count, pagination,
	schema-aware cells) and adds the spreadsheet layer: an active cell with a
	shift-extendable range, keyboard navigation, TSV copy, sticky frozen
	columns, and the Σ row of server aggregates. Editing lands in a later
	phase — this build reads.
-->

<script lang="ts" generics="T">
	import * as m from '$lib/paraglide/messages';
	import { Checkbox } from 'bits-ui';
	import Pagination from '$lib/components/primitives/navigation/Pagination.svelte';
	import Capsule from '$lib/components/primitives/data/Capsule.svelte';
	import FieldValue from '$lib/components/primitives/data/FieldValue.svelte';
	import TableToolbar from '$lib/table/TableToolbar.svelte';
	import type { FieldDef } from '$lib/doctype/types.js';
	import { humanize } from '$lib/doctype/types.js';
	import { hashColor } from '$lib/utils/color.js';
	import { errorMessage } from '$lib/datasource/bannerError.js';
	import { isTypingTarget } from '$lib/shortcuts.svelte';
	import { copyText } from '$lib/clipboard.js';
	import { createSelection } from './selection.svelte.js';
	import { cellCopyText, serializeTSV } from './clipboard.js';
	import { fetchSummaries, type FieldSummary } from './summary.js';
	import type { GridColumn, GridProps } from './types.js';

	let {
		columns,
		datasource,
		doctype = undefined,
		driver = undefined,
		filters = {},
		onFilterChange = undefined,
		sort = null,
		onSort = undefined,
		frozen = 0,
		selectable = false,
		selected = undefined,
		onSelect = undefined,
		onSelectAll = undefined,
		rowKey,
		pageSize = 25,
		onRowClick = undefined,
		onReferenceClick = undefined,
		toolbarActions = undefined
	}: GridProps<T> = $props();

	// ── Layout math — sticky frozen columns ──────────────────────────────

	/** Default column width when the config carries no px width. */
	const DEFAULT_COL_WIDTH = 160;
	/** Gutter (#) and checkbox column widths, in render order. */
	const GUTTER_WIDTH = 48;
	const CHECKBOX_WIDTH = 40;
	/** Row height — one density, no config (the design's 40px). */
	const ROW_HEIGHT = 40;

	/** Parse a column's px width; a non-px width renders at the default and
	 *  never freezes (the sticky offsets need concrete pixels). */
	function colWidth(col: GridColumn): number {
		const match = col.width?.match(/^(\d+(?:\.\d+)?)px$/);
		return match ? Number(match[1]) : DEFAULT_COL_WIDTH;
	}

	const colWidths = $derived(columns.map(colWidth));

	/** Sticky left offset per data column — `null` when the column scrolls. */
	const frozenLefts = $derived.by<(number | null)[]>(() => {
		const cap = Math.min(Math.max(0, frozen), columns.length);
		let left = GUTTER_WIDTH + (selectable ? CHECKBOX_WIDTH : 0);
		return columns.map((_, i) => {
			if (i >= cap) return null;
			const offset = left;
			left += colWidths[i];
			return offset;
		});
	});

	/** Which rendered cell is the rightmost sticky one — it carries the
	 *  frozen-edge shadow. */
	const lastSticky = $derived(
		Math.min(Math.max(0, frozen), columns.length) > 0 ? 'col' : selectable ? 'check' : 'gutter'
	);

	const gridTemplate = $derived(
		[
			`${GUTTER_WIDTH}px`,
			...(selectable ? [`${CHECKBOX_WIDTH}px`] : []),
			...colWidths.map((w) => `${w}px`)
		].join(' ')
	);

	// ── Internal state managed by the DataSource ─────────────────────────

	let items: T[] = $state([]);
	let total: number | undefined = $state(undefined);
	/** True while the count is a capped lower bound — the footer renders it
	 *  as an open range, never as an exact total. */
	let more = $state(false);
	let page: number = $state(1);
	// svelte-ignore state_referenced_locally — seed-only: the footer selector
	// owns the page size afterwards; the prop is the starting point, not a
	// live sync. (The Table's pattern.)
	let rowsPerPage: number = $state(pageSize);
	let loading = $state(false);
	let error: string | undefined = $state(undefined);
	// svelte-ignore state_referenced_locally — seed-only: the toolbar owns
	// the map afterwards; the prop is the starting point, not a live sync.
	let activeFilters: Record<string, unknown> = $state(filters);
	/** Σ-row values per column key, from the field-aggregate calls. */
	let summaries = $state<Map<string, FieldSummary>>(new Map());

	const summaryColumns = $derived(columns.filter((c) => c.summary));

	/** Fetch the current page — the Table's loader, flattened rows included. */
	async function loadData() {
		// Read every effect-tracked signal synchronously: the Σ columns ride
		// the same refetch as the rows.
		void summaryColumns;
		loading = true;
		error = undefined;
		try {
			const result = await datasource.list({
				page,
				items: rowsPerPage,
				sort: buildSortParam(),
				filters: buildFilters()
			});
			// The backend wraps each item in { data, meta } — flatten the user
			// content + the document id AND the system timestamps into the row,
			// exactly like the Table does.
			items = result.data.map(
				(item) =>
					({
						id: item.meta.id,
						created_at: item.meta.created_at,
						updated_at: item.meta.updated_at,
						...item.data
					}) as T
			);
			total = result.meta.count;
			more = result.meta.more;
			if (result.meta.more) {
				const counted = await datasource.list({
					aggregate: 'count',
					filters: buildFilters()
				});
				total = counted.meta.count;
				more = counted.meta.more;
			}
			// A refetch that shrank the data pulls the selection back in bounds.
			selection.clampTo(items.length - 1, columns.length - 1);
			// The Σ row answers per column with the same filters — a failed
			// column aggregate leaves its cell empty (fetchSummaries drops it).
			if (summaryColumns.length > 0) {
				summaries = await fetchSummaries(datasource, summaryColumns, buildFilters());
			} else {
				summaries = new Map();
			}
		} catch (e) {
			error = errorMessage(e, m.table_load_failed());
			items = [];
			total = 0;
			more = false;
			summaries = new Map();
		} finally {
			loading = false;
		}
	}

	function isEmpty(v: unknown): boolean {
		return v === '' || v == null || (typeof v === 'number' && Number.isNaN(v));
	}

	/** Compact the active filter map to only values worth sending. */
	function buildFilters(): Record<string, unknown> | undefined {
		const out: Record<string, unknown> = {};
		for (const [k, v] of Object.entries(activeFilters)) {
			if (!isEmpty(v)) out[k] = v;
		}
		return Object.keys(out).length > 0 ? out : undefined;
	}

	function buildSortParam(): string[] | undefined {
		return sort ? [`${sort.desc ? '-' : ''}${sort.key}`] : undefined;
	}

	// Reload whenever datasource, page, page size, sort, or filters change.
	// Also reload on mount (Svelte 5 $effect runs after first mount). All
	// five signals are read synchronously inside `loadData()` (call args and
	// the sort/filter builders run before the first await), so the effect
	// tracks them without bare reference reads.
	$effect(() => {
		loadData();
	});

	function handleFilterChange(next: Record<string, unknown>) {
		activeFilters = next;
		page = 1; // filter change → restart at first page
		onFilterChange?.(next);
	}

	function handleSort(key: string) {
		if (!onSort) return;
		onSort(key);
	}

	// ── Pagination helpers ───────────────────────────────────────────────

	const totalPages = $derived(total != null ? Math.max(1, Math.ceil(total / rowsPerPage)) : 0);

	const fmtNum = (n: number): string => n.toLocaleString();

	const rangeStart = $derived(total != null && total > 0 ? (page - 1) * rowsPerPage + 1 : 0);
	const rangeEnd = $derived(total != null ? Math.min(page * rowsPerPage, total) : 0);

	const PAGE_SIZE_OPTIONS: readonly number[] = [10, 25, 100, 250];

	const pageSizeOptions = $derived(
		PAGE_SIZE_OPTIONS.includes(rowsPerPage)
			? PAGE_SIZE_OPTIONS
			: [...PAGE_SIZE_OPTIONS, rowsPerPage].sort((a, b) => a - b)
	);

	function handlePageSizeChange(e: Event) {
		const next = Number((e.currentTarget as HTMLSelectElement).value);
		if (!Number.isInteger(next) || next < 1 || next === rowsPerPage) return;
		rowsPerPage = next;
		page = 1;
	}

	// ── Cell selection & keyboard ────────────────────────────────────────

	const selection = createSelection();
	const selRange = $derived(selection.range);
	const selSize = $derived(selection.size(selRange));

	const maxRow = $derived(items.length - 1);
	const maxCol = $derived(columns.length - 1);

	/** The row item the focus cell sits on — Enter/Space open its peek. */
	const focusItem = $derived.by<T | null>(() => {
		const focus = selection.focus;
		if (!focus || items.length === 0) return null;
		return items[Math.min(focus.row, items.length - 1)] ?? null;
	});

	function cellMouseDown(r: number, c: number, e: MouseEvent) {
		if (e.shiftKey) {
			selection.extendTo(r, c, maxRow, maxCol);
		} else {
			selection.setFocus(r, c, maxRow, maxCol);
		}
	}

	/** Drag-select: the primary button is already down, hovering extends. */
	function cellMouseEnter(r: number, c: number, e: MouseEvent) {
		if ((e.buttons & 1) === 0) return;
		if (e.shiftKey) return;
		selection.extendTo(r, c, maxRow, maxCol);
	}

	/** Gutter click selects the whole row (all data columns of the row). */
	function gutterMouseDown(r: number, e: MouseEvent) {
		if (maxCol < 0) return;
		if (e.shiftKey && selRange) {
			selection.extendTo(r, maxCol, maxRow, maxCol);
		} else {
			selection.setFocus(r, 0, maxRow, maxCol);
			selection.extendTo(r, maxCol, maxRow, maxCol);
		}
	}

	/** The TSV block for the current selection (or the focused cell). */
	function selectionTSV(): string | null {
		if (!selRange || items.length === 0) return null;
		const rows: string[][] = [];
		for (let r = selRange.rowStart; r <= selRange.rowEnd; r++) {
			const item = items[r] as Record<string, unknown> | undefined;
			if (!item) continue;
			const row = columns
				.slice(selRange.colStart, selRange.colEnd + 1)
				.map((col) => cellCopyText(fieldFor(col), item[col.key]));
			rows.push(row);
		}
		return serializeTSV(rows);
	}

	async function copySelection(): Promise<boolean> {
		const tsv = selectionTSV();
		if (tsv == null) return false;
		return copyText(tsv);
	}

	function handleKeydown(e: KeyboardEvent) {
		if (isTypingTarget(e.target)) return;
		const key = e.key;
		// Copy — the one chord the grid owns outside the arrow block.
		if ((e.metaKey || e.ctrlKey) && (key === 'c' || key === 'C')) {
			e.preventDefault();
			void copySelection();
			return;
		}
		if (e.metaKey || e.ctrlKey || e.altKey) return;
		const extend = e.shiftKey && key.startsWith('Arrow');
		switch (key) {
			case 'ArrowDown':
				e.preventDefault();
				selection.move(1, 0, extend, maxRow, maxCol);
				break;
			case 'ArrowUp':
				e.preventDefault();
				selection.move(-1, 0, extend, maxRow, maxCol);
				break;
			case 'ArrowRight':
				e.preventDefault();
				selection.move(0, 1, extend, maxRow, maxCol);
				break;
			case 'ArrowLeft':
				e.preventDefault();
				selection.move(0, -1, extend, maxRow, maxCol);
				break;
			case 'Home':
				e.preventDefault();
				selection.setFocus(0, 0, maxRow, maxCol);
				break;
			case 'End':
				e.preventDefault();
				selection.setFocus(maxRow, 0, maxRow, maxCol);
				break;
			case 'Enter':
			case ' ':
				// Read-only build: open the row like the table's Enter does.
				if (focusItem && onRowClick) {
					e.preventDefault();
					onRowClick(focusItem);
				}
				break;
			case 'Escape':
				selection.clear();
				break;
			default:
				break;
		}
	}

	// ── Selection statistics — client-side, over the loaded rows ─────────

	const selStats = $derived.by(() => {
		if (!selRange || selSize < 2) return null;
		let cells = 0;
		let ints = 0;
		let intSum = 0;
		const money = new Map<string, number>();
		for (let r = selRange.rowStart; r <= selRange.rowEnd; r++) {
			const item = items[r] as Record<string, unknown> | undefined;
			if (!item) continue;
			for (let c = selRange.colStart; c <= selRange.colEnd; c++) {
				const col = columns[c];
				if (!col) continue;
				const value = item[col.key];
				if (value == null) continue;
				cells++;
				const field = fieldFor(col);
				if (field?.type === 'integer' && typeof value === 'number') {
					ints++;
					intSum += value;
				} else if (field?.type === 'money' && typeof value === 'object' && value !== null) {
					const amount = Number((value as Record<string, unknown>).value);
					if (!Number.isFinite(amount)) continue;
					const ticker = String((value as Record<string, unknown>).currency ?? 'USD');
					money.set(ticker, (money.get(ticker) ?? 0) + amount);
				}
			}
		}
		if (cells === 0) return null;
		const moneyText = [...money.entries()]
			.sort(([a], [b]) => a.localeCompare(b))
			.map(([ticker, sum]) => `${ticker} ${fmtNum(sum)}`)
			.join(' · ');
		return {
			cells,
			intSum: ints > 0 ? intSum : null,
			intAvg: ints > 0 ? intSum / ints : null,
			moneyText: moneyText.length > 0 ? moneyText : null
		};
	});

	// ── Schema-aware cell rendering — the Table's renderer, reused ───────

	const SYSTEM_TS_KEYS = new Set(['created_at', 'updated_at']);

	/**
	 * Resolve the {@link FieldDef} backing this column. Synthetic timestamp
	 * columns (`created_at` / `updated_at`) are treated as `datetime` even
	 * though they are not part of the doctype's `fields` array — they are
	 * injected by `loadData` from `meta`.
	 */
	function fieldFor(col: GridColumn): FieldDef | null {
		if (!doctype) return null;
		if (SYSTEM_TS_KEYS.has(col.key)) {
			return { key: col.key, type: 'datetime' };
		}
		return doctype.fields.find((f) => f.key === col.key) ?? null;
	}

	/** `data` (computed) columns show the fx badge — never editable. */
	function isComputed(col: GridColumn): boolean {
		return fieldFor(col)?.type === 'data';
	}

	const colAlign = (col: GridColumn): string => col.align ?? 'left';

	// ── Checkbox selection ───────────────────────────────────────────────

	const checkedSet = $derived(selected ?? new Set<string>());

	const allSelected = $derived(
		selectable && items.length > 0 && items.every((d) => checkedSet.has(rowKey(d)))
	);

	const someSelected = $derived(
		selectable && !allSelected && items.some((d) => checkedSet.has(rowKey(d)))
	);

	// ── Σ-row rendering ──────────────────────────────────────────────────

	const aggLabel = (kind: string): string =>
		kind === 'count'
			? m.grid_agg_count()
			: kind === 'sum'
				? m.grid_agg_sum()
				: kind === 'avg'
					? m.grid_agg_avg()
					: kind === 'min'
						? m.grid_agg_min()
						: m.grid_agg_max();

	/** The numeric text for one Σ cell — money bags render per currency,
	 *  `avg` rounds to one decimal (the design's `43.6` form; the faithful
	 *  value stays in the data). */
	function summaryText(summary: FieldSummary | undefined, kind: string): string | null {
		if (!summary || summary.value == null) return null;
		const fmt = (n: number): string =>
			kind === 'avg' && !Number.isInteger(n) ? String(Math.round(n * 10) / 10) : fmtNum(n);
		if (typeof summary.value === 'number') return fmt(summary.value);
		return (
			Object.entries(summary.value)
				.sort(([a], [b]) => a.localeCompare(b))
				.map(([ticker, amount]) => `${ticker} ${fmt(Number(amount))}`)
				.join(' · ') || null
		);
	}
</script>

<div class="grid-wrap">
	{#if doctype}
		<TableToolbar {doctype} {driver} filters={activeFilters} onFilterChange={handleFilterChange}>
			{#snippet actions()}
				<!-- The export snippet reads key/label/filter/sort shapes the two
					surface column types share; the grid column type narrows it. -->
				{@render toolbarActions?.({
					columns: columns as unknown as import('$lib/table/types.js').Column<T>[],
					filters: buildFilters() ?? {},
					sort: sort ?? null
				})}
			{/snippet}
		</TableToolbar>
	{/if}
	{#if error}
		<div class="grid-error">{error}</div>
	{/if}

	<div class="grid-scroll">
		<div
			class="grid"
			style={`--grid-cols: ${gridTemplate}; --row-h: ${ROW_HEIGHT}px;`}
			role="grid"
			aria-rowcount={items.length}
			aria-colcount={columns.length + (selectable ? 1 : 0)}
			tabindex="0"
			onkeydown={handleKeydown}
		>
			<!-- header -->
			<div class="g-row g-head" role="row">
				<div
					class="g-cell gutter head-cell frozen"
					class:frozen-last={lastSticky === 'gutter'}
					style="left: 0"
					aria-hidden="true"
				>
					#
				</div>
				{#if selectable}
					<div
						class="g-cell check head-cell frozen"
						class:frozen-last={lastSticky === 'check'}
						style={`left: ${GUTTER_WIDTH}px`}
						role="columnheader"
						tabindex="-1"
					>
						<Checkbox.Root
							checked={allSelected}
							indeterminate={someSelected}
							onclick={onSelectAll}
							class="cbx"
							aria-label={m.table_select_all_aria()}
						/>
					</div>
				{/if}
				{#each columns as col, i (col.key)}
					{@const sticky = frozenLefts[i]}
					{@const frozenLast =
						sticky != null && i === Math.min(Math.max(0, frozen), columns.length) - 1}
					<div
						class="g-cell head-cell {colAlign(col)}"
						class:frozen={sticky != null}
						class:frozen-last={frozenLast}
						style={sticky != null ? `left: ${sticky}px` : ''}
						role="columnheader"
						tabindex="-1"
						aria-sort={sort?.key === col.key ? (sort.desc ? 'descending' : 'ascending') : undefined}
						aria-colindex={i + 1}
					>
						{#if col.sortable}
							<button type="button" class="head-sort" onclick={() => handleSort(col.key)}>
								<span class="head-label">
									{col.label}
									{#if sort?.key === col.key}<span class="sort-arrow" aria-hidden="true">
											{sort.desc ? '▼' : '▲'}</span
										>{/if}
								</span>
							</button>
						{:else}
							<span class="head-label">{col.label}</span>
						{/if}
						{#if isComputed(col)}
							<span class="fx" title={m.grid_fx_read_only()}>fx</span>
						{/if}
					</div>
				{/each}
			</div>

			<!-- body -->
			{#each items as item, r (rowKey(item))}
				<div class="g-row" role="row" aria-rowindex={r + 1}>
					<div
						class="g-cell gutter frozen"
						class:frozen-last={lastSticky === 'gutter'}
						style="left: 0"
						aria-hidden="true"
						onmousedown={(e) => gutterMouseDown(r, e)}
					>
						{r + 1}
					</div>
					{#if selectable}
						<div
							class="g-cell check frozen"
							class:frozen-last={lastSticky === 'check'}
							style={`left: ${GUTTER_WIDTH}px`}
							role="gridcell"
							tabindex="-1"
							aria-colindex={1}
						>
							<Checkbox.Root
								checked={checkedSet.has(rowKey(item))}
								onclick={() => onSelect?.(rowKey(item))}
								class="cbx"
								aria-label={m.table_select_row_aria()}
							/>
						</div>
					{/if}
					{#each columns as col, c (col.key)}
						{@const sticky = frozenLefts[c]}
						{@const frozenLast =
							sticky != null && c === Math.min(Math.max(0, frozen), columns.length) - 1}
						{@const inRange =
							selRange != null &&
							selRange.rowStart <= r &&
							r <= selRange.rowEnd &&
							selRange.colStart <= c &&
							c <= selRange.colEnd}
						{@const isFocus =
							inRange &&
							selRange!.rowStart === r &&
							selRange!.rowEnd === r &&
							selRange!.colStart === c &&
							selRange!.colEnd === c}
						<div
							class="g-cell {colAlign(col)}"
							class:frozen={sticky != null}
							class:frozen-last={frozenLast}
							class:in-range={inRange && !isFocus}
							class:focused={isFocus}
							class:computed={isComputed(col)}
							style={sticky != null ? `left: ${sticky}px` : ''}
							role="gridcell"
							tabindex="-1"
							aria-selected={inRange}
							aria-colindex={c + 1}
							data-row={r}
							data-col={c}
							onmousedown={(e) => cellMouseDown(r, c, e)}
							onmouseenter={(e) => cellMouseEnter(r, c, e)}
						>
							{@render dataCell(item, col)}
						</div>
					{/each}
				</div>
			{:else}
				{#if !loading && !error}
					<div class="g-empty">{m.table_records_empty()}</div>
				{/if}
			{/each}

			<!-- Σ row -->
			{#if summaryColumns.length > 0 && items.length > 0}
				<div class="g-row g-foot" role="row">
					<div
						class="g-cell gutter foot-cell frozen"
						class:frozen-last={lastSticky === 'gutter'}
						style="left: 0"
						aria-hidden="true"
					>
						Σ
					</div>
					{#if selectable}
						<div
							class="g-cell check foot-cell frozen"
							class:frozen-last={lastSticky === 'check'}
							style={`left: ${GUTTER_WIDTH}px`}
							role="gridcell"
							tabindex="-1"
							aria-colindex={1}
						></div>
					{/if}
					{#each columns as col, c (col.key)}
						{@const sticky = frozenLefts[c]}
						{@const frozenLast =
							sticky != null && c === Math.min(Math.max(0, frozen), columns.length) - 1}
						{@const text = col.summary ? summaryText(summaries.get(col.key), col.summary) : null}
						<div
							class="g-cell foot-cell {colAlign(col)}"
							class:frozen={sticky != null}
							class:frozen-last={frozenLast}
							style={sticky != null ? `left: ${sticky}px` : ''}
							role="gridcell"
							aria-colindex={c + 1}
						>
							{#if col.summary}
								<span class="agg-label">{aggLabel(col.summary)}</span>
								{#if text}
									<span class="agg-value">{text}</span>
								{:else}
									<span class="agg-missing">—</span>
								{/if}
							{/if}
						</div>
					{/each}
				</div>
			{/if}
		</div>
	</div>

	{#if loading && items.length === 0}
		<div class="grid-loading">{m.common_loading()}</div>
	{/if}

	{#if total != null}
		<div class="tfoot">
			{#if total > 0}
				<span>
					{#if more}
						{m.table_range_open({
							from: fmtNum(rangeStart),
							to: fmtNum(rangeEnd),
							total: fmtNum(total)
						})}
					{:else}
						{m.table_range_summary({
							from: fmtNum(rangeStart),
							to: fmtNum(rangeEnd),
							total: fmtNum(total)
						})}
					{/if}
					{#if selectable && (selected?.size ?? 0) > 0}
						· {m.table_selected_count({ count: selected?.size ?? 0 })}
					{/if}
				</span>
				{#if selStats}
					<span class="sel-chip">
						<span class="sel-cells">{m.grid_range_cells({ count: selStats.cells })}</span>
						{#if selStats.intSum != null}
							<span class="sel-stat">
								{aggLabel('sum')} <span class="mono">{fmtNum(selStats.intSum)}</span>
							</span>
						{/if}
						{#if selStats.intAvg != null}
							<span class="sel-stat">
								{aggLabel('avg')}
								<span class="mono">{fmtNum(Math.round(selStats.intAvg * 10) / 10)}</span>
							</span>
						{/if}
						{#if selStats.moneyText}
							<span class="sel-stat"><span class="mono">{selStats.moneyText}</span></span>
						{/if}
					</span>
				{/if}
			{/if}

			<span class="sp"></span>

			<label class="rows-per-page">
				<span>{m.table_rows_label()}</span>
				<select value={rowsPerPage} onchange={handlePageSizeChange}>
					{#each pageSizeOptions as size (size)}
						<option value={size}>{size}</option>
					{/each}
				</select>
			</label>

			{#if totalPages > 1}
				<Pagination current={page} total={totalPages} onchange={(p) => (page = p)} />
			{/if}
		</div>
	{/if}
</div>

{#snippet dataCell(item: T, col: GridColumn)}
	{@const value = (item as Record<string, unknown>)[col.key]}
	{@const field = fieldFor(col)}
	<FieldValue {value} fieldType={field?.type ?? null} fieldDef={field} detectIsoDates>
		{#snippet referenceCell(ref, fd)}
			<Capsule
				{driver}
				reference={ref}
				qualifiedDoctype={fd?.doctype}
				onreferenceclick={onReferenceClick}
			/>
		{/snippet}
		{#snippet enumCell(v)}
			{@const entry = field?.values?.find((e) => e.key === v) ?? null}
			{@const enumLabel = entry?.label ?? humanize(String(v))}
			{@const enumColor = entry?.color ?? hashColor(String(v))}
			<!-- The dot + tint carry the declared colour; the label stays in the
				theme ink so the chip passes AA on light and dark (a raw enum
				colour on the 14% tint can sit under 4.5:1 — the Table's shared
				snippet has the same latent issue, untripped by its fixtures). -->
			<span
				class="cell-enum"
				style={`background: color-mix(in srgb, ${enumColor} 14%, transparent);`}
			>
				<span class="cell-enum-dot" style={`background: ${enumColor}`}></span>
				{enumLabel}
			</span>
		{/snippet}
		{#snippet booleanCell(v)}
			<span class="cell-bool" class:on={v === true} title={String(v)}>
				{v === true ? '✓' : '✕'}
			</span>
		{/snippet}
		{#snippet plainCell(v)}
			<span class="cell-text">{String(v)}</span>
		{/snippet}
	</FieldValue>
{/snippet}

<style>
	.grid-wrap {
		display: flex;
		flex-direction: column;
		gap: 0;
		min-width: 0;
		min-height: 0;
	}

	.grid-error {
		padding: 10px 16px;
		color: var(--danger);
		font-size: 13px;
	}

	.grid-loading {
		padding: 24px;
		color: var(--text-3);
		font-size: 13px;
	}

	.grid-scroll {
		overflow: auto;
		max-width: 100%;
		border: 1px solid var(--border);
		border-radius: var(--r);
		background: var(--surface);
	}

	.grid {
		display: inline-block;
		min-width: 100%;
		outline: none;
	}

	.g-row {
		display: grid;
		grid-template-columns: var(--grid-cols);
		width: max-content;
		min-width: 100%;
	}

	/* ── Cells ── */

	.g-cell {
		height: var(--row-h);
		box-sizing: border-box;
		padding: 0 12px;
		display: flex;
		align-items: center;
		gap: 8px;
		border-right: 1px solid var(--border);
		border-bottom: 1px solid var(--border);
		font-size: 13.5px;
		color: var(--text);
		white-space: nowrap;
		overflow: hidden;
		position: relative;
		user-select: none;
		min-width: 0;
		background: var(--surface);
	}

	.g-cell.right {
		justify-content: flex-end;
	}

	.g-cell.center {
		justify-content: center;
	}

	/* numerics read as data — tabular digits keep the column aligned */
	.g-cell.right :global(*) {
		font-variant-numeric: tabular-nums;
	}

	.g-cell.frozen {
		position: sticky;
		z-index: 2;
	}

	.g-cell.frozen-last {
		box-shadow:
			inset -1px 0 0 var(--border-strong),
			8px 0 10px -8px rgba(16, 24, 40, 0.35);
	}

	/* ── Gutter / checkbox ── */

	.gutter {
		justify-content: center;
		color: var(--text-3);
		font-family: var(--font-mono);
		font-size: 12px;
		background: var(--surface-2);
		padding: 0;
		cursor: default;
	}

	.check {
		justify-content: center;
		padding: 0;
		background: var(--surface-2);
	}

	/* ── Header ── */

	.g-head .g-cell {
		position: sticky;
		top: 0;
		z-index: 3;
		height: 38px;
		font-size: 11.5px;
		letter-spacing: 0.06em;
		text-transform: uppercase;
		color: var(--text-2);
		font-weight: 600;
		background: var(--surface-2);
	}

	.g-head .g-cell.frozen {
		z-index: 4;
	}

	.head-label {
		overflow: hidden;
		text-overflow: ellipsis;
	}

	.head-sort {
		background: none;
		border: 0;
		padding: 0;
		margin: 0;
		font: inherit;
		color: inherit;
		letter-spacing: inherit;
		text-transform: inherit;
		cursor: pointer;
		display: flex;
		align-items: center;
		gap: 4px;
		min-width: 0;
	}

	.head-sort:focus-visible {
		outline: 2px solid var(--accent-ink);
		outline-offset: 1px;
		border-radius: 2px;
	}

	.sort-arrow {
		color: var(--accent-ink);
		font-size: 10px;
	}

	.fx {
		font-family: var(--font-mono);
		font-size: 10px;
		color: var(--accent-ink);
		border: 1px solid var(--accent-weak);
		border-radius: 4px;
		padding: 0 4px;
		text-transform: none;
		letter-spacing: 0;
		flex-shrink: 0;
	}

	/* ── Body ── */

	.g-row:not(.g-head):not(.g-foot) .g-cell:hover {
		background: var(--surface-2);
	}

	.g-cell.in-range {
		background: var(--accent-weak);
	}

	.g-cell.focused {
		box-shadow: inset 0 0 0 2px var(--accent);
		z-index: 1;
	}

	.g-cell.computed {
		color: var(--text-2);
	}

	/* ── Σ row ── */

	.g-foot .g-cell {
		height: 42px;
		background: var(--surface-2);
		border-bottom: none;
		font-weight: 500;
	}

	.g-foot .gutter {
		color: var(--accent-ink);
		font-size: 14px;
	}

	.agg-label {
		font-size: 10.5px;
		letter-spacing: 0.08em;
		color: var(--text-3);
		font-weight: 600;
	}

	.agg-value {
		font-family: var(--font-mono);
		font-size: 12.5px;
	}

	.agg-missing {
		color: var(--text-3);
	}

	/* ── Cell content (the FieldValue reuse) ── */

	.cell-enum {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		padding: 2px 10px;
		border-radius: 999px;
		font-size: 12.5px;
		font-weight: 600;
		color: var(--text);
	}

	.cell-enum-dot {
		width: 6px;
		height: 6px;
		border-radius: 50%;
	}

	.cell-bool {
		width: 18px;
		height: 18px;
		border-radius: 4px;
		display: inline-flex;
		align-items: center;
		justify-content: center;
		font-size: 11px;
		font-weight: 700;
		color: var(--text-3);
	}

	.cell-bool.on {
		background: var(--ok);
		color: var(--ok-ink);
	}

	/* ── Footer ── */

	.tfoot {
		display: flex;
		align-items: center;
		gap: 12px;
		padding: 10px 12px;
		border-top: 1px solid var(--border);
		font-size: 12.5px;
		color: var(--text-2);
		flex-wrap: wrap;
	}

	.tfoot .sp {
		flex: 1;
	}

	.rows-per-page {
		display: inline-flex;
		align-items: center;
		gap: 8px;
	}

	.rows-per-page select {
		border: 1px solid var(--border);
		border-radius: var(--r-sm);
		background: var(--surface);
		color: var(--text);
		padding: 4px 6px;
		font-size: 12.5px;
	}

	.sel-chip {
		display: inline-flex;
		align-items: center;
		gap: 14px;
		padding: 3px 10px;
		border-radius: var(--r-sm);
		background: var(--accent-weak);
		color: var(--text);
		font-size: 12px;
	}

	.sel-cells {
		color: var(--accent-ink);
		font-weight: 600;
	}

	.sel-stat {
		display: inline-flex;
		align-items: center;
		gap: 4px;
	}

	.sel-stat .mono,
	.mono {
		font-family: var(--font-mono);
		font-size: 12px;
	}

	/* ── Checkbox (shared with the table) ── */

	:global(.cbx) {
		width: 15px;
		height: 15px;
		border: 1.5px solid var(--border-strong);
		border-radius: 4px;
		display: inline-flex;
		align-items: center;
		justify-content: center;
		vertical-align: middle;
		background: var(--surface);
		cursor: pointer;
		padding: 0;
		font: inherit;
		color: inherit;
	}

	:global(.cbx[data-state='checked']),
	:global(.cbx[data-state='indeterminate']) {
		background: var(--accent);
		border-color: var(--accent);
		color: var(--on-accent);
	}
</style>
