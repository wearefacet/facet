<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" generics="T">
	import * as m from '$lib/paraglide/messages';
	import { Checkbox } from 'bits-ui';
	import Pagination from '$lib/components/primitives/navigation/Pagination.svelte';
	import Capsule from '$lib/components/primitives/data/Capsule.svelte';
	import FieldValue from '$lib/components/primitives/data/FieldValue.svelte';
	import type { FieldDef } from '$lib/doctype/types.js';
	import { humanize } from '$lib/doctype/types.js';
	import { hashColor } from '$lib/utils/color.js';
	import { errorMessage } from '$lib/datasource/bannerError.js';
	import { toast } from '$lib/toast.svelte.js';
	import { can } from '$lib/permissions.svelte';
	import type { ReferenceClickHandler } from '$lib/template-types.js';
	import { resolveArtifact, type ArtifactGrant } from '$lib/artifacts.js';
	import type { Column, SortState, ToolbarActionsArgs } from './types.js';
	import type { DataSource } from '$lib/datasource/interface.js';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import type { DoctypeDef } from '$lib/doctype/types.js';
	import TableToolbar from './TableToolbar.svelte';
	import {
		isInteractiveTarget,
		isTypingTarget,
		registerRouteShortcuts,
		type ShortcutEntry
	} from '$lib/shortcuts.svelte';

	let {
		columns,
		datasource,
		sort: initialSort = null,
		onSort: onSortCallback,
		selectable = false,
		selected = new Set<string>(),
		onSelect,
		onSelectAll,
		rowKey,
		pageSize = 25,
		doctype,
		driver,
		filters: initialFilters = {},
		onFilterChange,
		onRowClick,
		onReferenceClick,
		/** Artifact metadata fetch for `file` cells. Defaults to the cached
		 *  `GET /Api/core/artifacts/:id` lookup; stories pass a synthetic one. */
		fetchArtifact,
		/** Right-aligned action affordances rendered beside the toolbar's filters. */
		toolbarActions
	}: {
		/** Column definitions — purely presentational. */
		columns: Column<T>[];
		/** DataSource used to load rows with pagination, sorting, and filtering. */
		datasource: DataSource<T>;
		/**
		 * Seed for the internal sort state — picked up once at mount and then
		 * owned by the table's own header clicks (`sortState` is not synced from
		 * this prop afterwards).
		 */
		sort?: SortState | null;
		/** Called when a sortable header is clicked (for external observers). */
		onSort?: (key: string) => void;
		/** Whether the first column should be a checkbox for row selection. */
		selectable?: boolean;
		/** Set of currently selected row keys. */
		selected?: Set<string>;
		/** Called with the row key when a checkbox is toggled. */
		onSelect?: (key: string) => void;
		/** Called when the header checkbox is toggled. */
		onSelectAll?: () => void;
		/** Function that returns a stable unique key for a row item. */
		rowKey: (item: T) => string;
		/**
		 * Seed for the rows-per-page selector. Defaults to 25. The table owns
		 * the value afterwards — the user picks from 10, 25, 100, 250 (a seeded
		 * size outside that list stays pickable until the user changes it).
		 */
		pageSize?: number;
		/** Doctype definition enabling the schema-aware toolbar (search + filters). */
		doctype?: DoctypeDef;
		/** Driver used to resolve `reference` filter comboboxes. */
		driver?: DataDriver;
		/** Active filter map (`field__op` → value). Resets to page 1 on change. */
		filters?: Record<string, unknown>;
		/** Called whenever the toolbar changes the active filters. */
		onFilterChange?: (filters: Record<string, unknown>) => void;
		/** Called with the row item when a body row (non-checkbox) is clicked. */
		onRowClick?: (item: T) => void;
		/**
		 * Click handler forwarded to reference capsules rendered by the
		 * schema-aware default cell renderer. When unset, reference capsules
		 * inside the table are display-only (not clickable).
		 */
		onReferenceClick?: ReferenceClickHandler;
		/**
		 * Artifact metadata fetch for `file` cells — the dense cell shows the
		 * filename when the artifact is cached and falls back to the id as the
		 * tooltip. Defaults to the shared cached `GET /Api/core/artifacts/:id`
		 * lookup; stories pass a synthetic one.
		 */
		fetchArtifact?: (id: string) => Promise<ArtifactGrant>;
		/** Right-aligned action affordances rendered beside the toolbar's filters.
		 * The snippet receives the table's current state (columns, the compacted
		 * filter map the datasource receives, and the sort) so an export action
		 * renders exactly what the table shows. */
		toolbarActions?: import('svelte').Snippet<[ToolbarActionsArgs<T>]>;
	} = $props();

	// ── Keyboard row navigation ──────────────────────────────────────────
	//
	// The table registers its own route-scoped shortcuts: j/k/↑/↓ move a
	// highlight across the loaded page's rows, Enter opens the highlighted
	// row through `onRowClick` (the same path a mouse click takes), Escape
	// clears the highlight, and `/` focuses the toolbar's search input —
	// `Mod+K` belongs to the global command palette (see
	// doc/frontend/command-palette.md). Registration is gated: navigation
	// only when rows are openable (`onRowClick` set — trash mode is not),
	// search keys only when the doctype declares a `search` template. The
	// handler closures read state at keypress time, so filter/sort/page
	// changes need no re-registration.

	let toolbarEl = $state<{ focusSearch(): boolean } | undefined>(undefined);
	/** The highlighted row's key — `null` when no row is highlighted. */
	let activeKey: string | null = $state(null);
	let tbodyEl: HTMLTableSectionElement | undefined;

	/** True when the doctype exposes the free-text search box. */
	const searchable = $derived((doctype?.search?.length ?? 0) > 0);

	function scrollToRow(index: number): void {
		// tbody rows mirror `items` 1:1 (the empty-state row only exists when
		// `items` is empty, and navigation never runs then).
		tbodyEl?.rows[index]?.scrollIntoView({ block: 'nearest' });
	}

	function moveActive(delta: 1 | -1): boolean {
		if (items.length === 0) return false;
		const idx = activeKey ? items.findIndex((it) => rowKey(it) === activeKey) : -1;
		const next =
			idx === -1
				? delta === 1
					? 0
					: items.length - 1
				: Math.min(items.length - 1, Math.max(0, idx + delta));
		activeKey = rowKey(items[next]);
		scrollToRow(next);
		return true;
	}

	function openActive(): boolean {
		if (!activeKey || !onRowClick) return false;
		const item = items.find((it) => rowKey(it) === activeKey);
		if (!item) return false;
		onRowClick(item);
		return true;
	}

	/**
	 * The table's route-scoped entries. Built by a plain helper — never
	 * inline in the registration `$effect` — so the effect stays a thin
	 * gate: it only tracks the two gate props and registers the result.
	 */
	function shortcutEntries(): ShortcutEntry[] {
		const entries: ShortcutEntry[] = [];
		if (onRowClick) {
			entries.push(
				{
					id: 'table.next',
					keys: 'j',
					label: m.shortcuts_list_next(),
					group: 'list',
					allowRepeat: true,
					handler: () => moveActive(1)
				},
				{
					id: 'table.next-alt',
					keys: 'ArrowDown',
					label: m.shortcuts_list_next(),
					group: 'list',
					allowRepeat: true,
					handler: () => moveActive(1)
				},
				{
					id: 'table.prev',
					keys: 'k',
					label: m.shortcuts_list_prev(),
					group: 'list',
					allowRepeat: true,
					handler: () => moveActive(-1)
				},
				{
					id: 'table.prev-alt',
					keys: 'ArrowUp',
					label: m.shortcuts_list_prev(),
					group: 'list',
					allowRepeat: true,
					handler: () => moveActive(-1)
				},
				{
					id: 'table.open',
					keys: 'Enter',
					label: m.shortcuts_list_open(),
					group: 'list',
					// A focused button/link owns Enter natively — never steal it.
					when: (e) => !isInteractiveTarget(e.target) && activeKey !== null,
					handler: () => openActive()
				},
				{
					id: 'table.clear',
					keys: 'Escape',
					label: m.shortcuts_list_clear(),
					group: 'list',
					// Only with a highlight to clear, and not from typing targets —
					// an input's native Escape (dropdown close, IME cancel) wins.
					when: (e) => activeKey !== null && !isTypingTarget(e.target),
					handler: () => {
						activeKey = null;
						return true;
					}
				}
			);
		}
		if (searchable) {
			entries.push({
				id: 'table.search-slash',
				keys: '/',
				label: m.shortcuts_search_filter(),
				group: 'list',
				handler: () => toolbarEl?.focusSearch() ?? false
			});
		}
		return entries;
	}

	$effect(() => {
		// Track the two gates so a change (e.g. a trash-mode toggle) re-runs
		// this effect and re-registers the matching entry set. Everything else
		// — building the entries, touching the registry — is plain data work
		// with no signal writes, so the effect can never loop.
		void onRowClick;
		void searchable;
		const entries = shortcutEntries();
		if (entries.length === 0) return;
		return registerRouteShortcuts(entries);
	});

	// ── Internal state managed by the DataSource ─────────────────────────

	let items: T[] = $state([]);
	let total: number | undefined = $state(undefined);
	/** True while the count is a capped lower bound — the footer renders it
	 *  as an open range, never as an exact total. */
	let more = $state(false);
	let page: number = $state(1);
	// svelte-ignore state_referenced_locally — seed-only: the footer selector
	// owns the page size afterwards; the prop is the starting point, not a
	// live sync.
	let rowsPerPage: number = $state(pageSize);
	// svelte-ignore state_referenced_locally — seed-only: header clicks own
	// `sortState` afterwards; the prop is the starting point, not a live sync.
	let sortState: SortState | null = $state<SortState | null>(initialSort);
	let loading: boolean = $state(true);
	let error: string | undefined = $state(undefined);

	/** Live filter map. A writable derived: reads the prop until the toolbar
	 *  assigns an override; a change of `initialFilters` (external reset) drops
	 *  the override, so parent resets always reach the inputs without
	 *  clobbering in-flight toolbar edits. */
	let activeFilters: Record<string, unknown> = $derived({ ...initialFilters });

	/** Build sort array for the datasource list call. */
	function buildSortParam(): string[] | undefined {
		if (!sortState) return undefined;
		return [`${sortState.desc ? '-' : ''}${sortState.key}`];
	}

	/** True when a filter value is empty/blank and should not be sent. */
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

	/** Fetch the current page from the datasource. */
	async function loadData() {
		loading = true;
		error = undefined;
		try {
			const result = await datasource.list({
				page,
				items: rowsPerPage,
				sort: buildSortParam(),
				filters: buildFilters()
			});
			// The backend wraps each item in { data, meta } — flatten the
			// user content + the document id AND the system-managed timestamps
			// (created_at, updated_at) into the row. Columns with those keys
			// then render like any other doctype field (kept outside `data`
			// on the API side so they remain readable regardless of which
			// fields the doctype declares).
			items = result.data.map(
				(item) =>
					({
						id: item.meta.id,
						created_at: item.meta.created_at,
						updated_at: item.meta.updated_at,
						...item.data
					}) as T
			);
			// `meta.count` is offset-relative: with `more` set it is only a lower
			// bound, never a total. Mark the footer open at once, then fetch the
			// real filtered total with `aggregate: 'count'` (capped at 1000).
			// Without `more` the page-relative count is already exact.
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
		} catch (e) {
			error = errorMessage(e, m.table_load_failed());
			items = [];
			total = 0;
			more = false;
		} finally {
			loading = false;
		}
	}

	// Reload whenever datasource, page, page size, sort, or filters change.
	// Also reload on mount (Svelte 5 $effect runs after first mount). All five
	// signals are read synchronously inside `loadData()` (call args and the
	// sort/filter builders run before the first await), so the effect tracks
	// them without bare reference reads.
	$effect(() => {
		loadData();
	});

	function handleFilterChange(next: Record<string, unknown>) {
		activeFilters = next;
		page = 1; // filter change → restart at first page
		onFilterChange?.(next);
	}

	// ── Sort handler ─────────────────────────────────────────────────────

	function handleSort(key: string) {
		if (sortState?.key === key) {
			sortState = { key, desc: !sortState.desc };
		} else {
			sortState = { key, desc: false };
		}
		page = 1; // reset to first page on sort change
		onSortCallback?.(key);
	}

	// ── Pagination helpers ───────────────────────────────────────────────

	const totalPages = $derived(total != null ? Math.max(1, Math.ceil(total / rowsPerPage)) : 0);

	const fmtNum = (n: number): string => n.toLocaleString();

	const rangeStart = $derived(total != null && total > 0 ? (page - 1) * rowsPerPage + 1 : 0);
	const rangeEnd = $derived(total != null ? Math.min(page * rowsPerPage, total) : 0);

	// ── Rows-per-page selector ───────────────────────────────────────────

	/** Rows-per-page choices offered in the footer selector. */
	const PAGE_SIZE_OPTIONS: readonly number[] = [10, 25, 100, 250];

	/** Selector options — a seeded size outside the standard list is kept in
	 *  the pick list so the select never shows a value it cannot represent. */
	const pageSizeOptions = $derived(
		PAGE_SIZE_OPTIONS.includes(rowsPerPage)
			? PAGE_SIZE_OPTIONS
			: [...PAGE_SIZE_OPTIONS, rowsPerPage].sort((a, b) => a - b)
	);

	/** Apply the picked page size and restart at the first page — the same
	 *  reset rule as filter and sort changes. */
	function handlePageSizeChange(e: Event) {
		const next = Number((e.currentTarget as HTMLSelectElement).value);
		if (!Number.isInteger(next) || next < 1 || next === rowsPerPage) return;
		rowsPerPage = next;
		page = 1;
	}

	// ── Alignment helpers ────────────────────────────────────────────────

	const colAlign = (col: Column<T>): string => col.align ?? 'left';

	const thClass = (col: Column<T>): string => {
		const parts: string[] = [];
		const align = colAlign(col);
		if (align !== 'left') parts.push(align);
		if (sortState && sortState.key === col.key) {
			parts.push('sorted');
			if (sortState.desc) parts.push('desc');
		}
		return parts.join(' ');
	};

	const tdClass = (col: Column<T>): string => {
		const align = colAlign(col);
		return align !== 'left' ? align : '';
	};

	// ── Selection helpers ────────────────────────────────────────────────

	const allSelected = $derived(
		selectable && items.length > 0 && items.every((d) => selected.has(rowKey(d)))
	);

	const someSelected = $derived(
		selectable && !allSelected && items.some((d) => selected.has(rowKey(d)))
	);

	// ── Schema-aware default cell renderer ─────────────────────────
	// When a column has no explicit `render` snippet but the table has a
	// `doctype`, the shared FieldValue primitive draws the cell from the
	// column's underlying field type. Explicit `render` snippets always win,
	// so per-column overrides (e.g. the Money story) stay authoritative.
	// A collection-reference cell carries a JSON array — FieldValue calls
	// `referenceCell` once per qualified token, so each element hydrates its
	// own Capsule (a joined id would 404 on every show route).

	/** System-managed timestamp columns synthesized by `loadData`. */
	const SYSTEM_TS_KEYS = new Set(['created_at', 'updated_at']);

	/**
	 * Resolve the {@link FieldDef} backing this column. Synthetic timestamp
	 * columns (`created_at` / `updated_at`) are treated as `datetime` even
	 * though they are not part of the doctype's `fields` array — they are
	 * injected by `loadData` from `meta`.
	 */
	function fieldFor(col: Column<T>): FieldDef | null {
		if (!doctype) return null;
		if (SYSTEM_TS_KEYS.has(col.key)) {
			return { key: col.key, type: 'datetime' };
		}
		return doctype.fields.find((f) => f.key === col.key) ?? null;
	}

	// ── Inline boolean edit ──────────────────────────────────────────────
	// A column marked `editable` whose field is a plain `boolean` renders its
	// cell as a toggle. Clicking applies `{ [key]: next }` straight through
	// the DataSource (the backend deep-merges and re-validates). The affordance
	// only renders when the viewer holds `update` on the doctype — a UI hint;
	// the WriteEnforcer re-checks every mutation server-side.

	/** `rowId:colKey` stamps with an in-flight inline update — the toggle is disabled. */
	let inlinePending = $state<Set<string>>(new Set());

	/** Whether this column's cell renders as an inline boolean toggle. */
	function inlineEditable(col: Column<T>, field: FieldDef | null): boolean {
		if (!col.editable || !doctype || !field) return false;
		if (field.type !== 'boolean' || field.read_only || field.write_only) return false;
		return can(`${doctype.domain}.${doctype.doctype}`, 'update');
	}

	/** Flip a boolean cell and persist it. Optimistic — reverts on failure. */
	async function toggleInlineBoolean(item: T, col: Column<T>, e: MouseEvent) {
		e.stopPropagation(); // a cell toggle never opens the row's peek drawer
		const field = fieldFor(col);
		if (!doctype || !field || field.type !== 'boolean') return;
		const id = rowKey(item);
		const stamp = `${id}:${col.key}`;
		if (inlinePending.has(stamp)) return;
		const next = (item as Record<string, unknown>)[col.key] !== true;
		const previous = items;
		inlinePending = new Set(inlinePending).add(stamp);
		items = items.map((r) =>
			rowKey(r) === id ? ({ ...(r as Record<string, unknown>), [col.key]: next } as T) : r
		);
		try {
			const saved = await datasource.doc(id).update({ [col.key]: next });
			items = items.map((r) =>
				rowKey(r) === id
					? ({ ...(r as Record<string, unknown>), updated_at: saved.meta.updated_at } as T)
					: r
			);
		} catch (err) {
			items = previous;
			toast({ message: errorMessage(err, m.common_save_failed()), variant: 'error' });
		} finally {
			const rest = new Set(inlinePending);
			rest.delete(stamp);
			inlinePending = rest;
		}
	}
</script>

<div class="table-wrap">
	{#if doctype}
		<TableToolbar
			bind:this={toolbarEl}
			{doctype}
			{driver}
			filters={activeFilters}
			onFilterChange={handleFilterChange}
		>
			{#snippet actions()}
				{@render toolbarActions?.({ columns, filters: buildFilters() ?? {}, sort: sortState })}
			{/snippet}
		</TableToolbar>
	{/if}
	{#if error}
		<div class="table-error">{error}</div>
	{/if}
	<table>
		<thead>
			<tr>
				{#if selectable}
					<th class="th-checkbox" aria-label={m.table_select_all_aria()}>
						<Checkbox.Root
							checked={allSelected}
							indeterminate={someSelected}
							onclick={onSelectAll}
							class="cbx"
							aria-label={m.table_select_all_aria()}
						/>
					</th>
				{/if}

				{#each columns as col (col.key)}
					<th
						class={thClass(col)}
						style={col.width ? `width: ${col.width}` : ''}
						aria-sort={sortState?.key === col.key
							? sortState.desc
								? 'descending'
								: 'ascending'
							: undefined}
						onclick={col.sortable ? () => handleSort(col.key) : undefined}
						tabindex={col.sortable ? 0 : undefined}
						onkeydown={col.sortable
							? (e) => {
									if (e.key === 'Enter' || e.key === ' ') {
										e.preventDefault();
										handleSort(col.key);
									}
								}
							: undefined}
					>
						{#if col.sortable}
							<span class="sort-wrap">{col.label} <span class="sort-arrow">▲</span></span>
						{:else}
							{col.label}
						{/if}
					</th>
				{/each}
			</tr>
		</thead>
		<tbody bind:this={tbodyEl}>
			{#each items as item (rowKey(item))}
				<tr
					class="row"
					class:clickable={!!onRowClick}
					class:active={rowKey(item) === activeKey}
					onclick={onRowClick ? () => onRowClick(item) : undefined}
				>
					{#if selectable}
						<td class="td-checkbox">
							<Checkbox.Root
								checked={selected.has(rowKey(item))}
								onclick={() => onSelect?.(rowKey(item))}
								class="cbx"
								aria-label={m.table_select_row_aria()}
							/>
						</td>
					{/if}

					{#each columns as col (col.key)}
						<td class={tdClass(col)}>
							{#if col.render}
								{@render col.render(item, col)}
							{:else}
								{@render defaultCell(item, col)}
							{/if}
						</td>
					{/each}
				</tr>
			{:else}
				{#if !loading && !error}
					<tr class="row-empty">
						<td colspan={columns.length + (selectable ? 1 : 0)}>{m.table_records_empty()}</td>
					</tr>
				{/if}
			{/each}
		</tbody>
	</table>

	{#if loading && items.length === 0}
		<div class="table-loading">{m.common_loading()}</div>
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
					{#if selected.size > 0}
						· {m.table_selected_count({ count: selected.size })}
					{/if}
				</span>
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

{#snippet defaultCell(item: T, col: Column<T>)}
	{@const value = (item as Record<string, unknown>)[col.key]}
	{@const field = fieldFor(col)}
	<FieldValue
		{value}
		fieldType={field?.type ?? null}
		fieldDef={field}
		detectIsoDates
		fetchArtifact={fetchArtifact ?? resolveArtifact}
	>
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
			<span
				class="cell-enum"
				style={`background: color-mix(in srgb, ${enumColor} 14%, transparent); color: ${enumColor};`}
			>
				<span class="cell-enum-dot" style={`background: ${enumColor}`}></span>
				{enumLabel}
			</span>
		{/snippet}
		{#snippet booleanCell(v)}
			{@const editable = inlineEditable(col, field)}
			{#if editable}
				{@const stamp = `${rowKey(item)}:${col.key}`}
				<button
					type="button"
					class="cell-bool"
					class:on={v === true}
					aria-pressed={v === true}
					aria-label={m.table_bool_toggle_aria({ field: col.label ?? col.key })}
					title={m.table_bool_toggle_aria({ field: col.label ?? col.key })}
					disabled={inlinePending.has(stamp)}
					onclick={(e) => toggleInlineBoolean(item, col, e)}
				>
					{v === true ? '✓' : '✕'}
				</button>
			{:else}
				<span class="cell-bool" class:on={v === true} title={String(v)}>
					{#if v === true}
						✓
					{:else}
						✕
					{/if}
				</span>
			{/if}
		{/snippet}
		{#snippet plainCell(v)}
			<span class="cell-text">{String(v)}</span>
		{/snippet}
	</FieldValue>
{/snippet}

<style>
	/* ---- table element ---- */
	.table-wrap {
		overflow-x: auto;
	}

	.table-wrap table {
		width: 100%;
		border-collapse: collapse;
		font-size: 13px;
	}

	/* ---- header ---- */
	.table-wrap thead th {
		text-align: left;
		font-weight: 600;
		font-size: 11px;
		letter-spacing: 0.05em;
		text-transform: uppercase;
		color: var(--text-3);
		padding: 11px 14px;
		border-bottom: 1px solid var(--border);
		white-space: nowrap;
		position: sticky;
		top: 0;
		background: var(--surface);
		cursor: pointer;
		user-select: none;
	}

	.table-wrap thead th .sort-wrap {
		display: inline-flex;
		align-items: center;
		gap: 5px;
	}

	.table-wrap thead th .sort-arrow {
		opacity: 0.35;
		transition: transform 0.15s;
	}

	.table-wrap thead th.sorted {
		color: var(--text);
	}

	.table-wrap thead th.sorted .sort-arrow {
		opacity: 1;
	}

	.table-wrap thead th.sorted.desc .sort-arrow {
		transform: rotate(180deg);
	}

	.table-wrap thead th.right {
		text-align: right;
	}

	.table-wrap thead th.center {
		text-align: center;
	}

	/* ---- header checkbox ---- */
	.table-wrap .th-checkbox {
		width: 38px;
		min-width: 38px;
	}

	/* ---- body ---- */
	.table-wrap tbody td {
		padding: 11px 14px;
		border-bottom: 1px solid var(--border);
		vertical-align: middle;
	}

	.table-wrap tbody tr:hover,
	.table-wrap tbody tr.active {
		background: var(--surface-2);
	}

	.table-wrap tbody tr.clickable {
		cursor: pointer;
	}

	.table-wrap tbody tr:last-child td {
		border-bottom: none;
	}

	.table-wrap .td-checkbox {
		width: 38px;
		min-width: 38px;
	}

	.table-wrap td.right {
		text-align: right;
		font-family: var(--font-mono);
	}

	.table-wrap td.center {
		text-align: center;
	}

	/* ---- checkbox (Bits UI Checkbox.Root) ---- */
	.table-wrap .cbx {
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

	.table-wrap :global(.cbx[data-state='checked']),
	.table-wrap :global(.cbx[data-state='indeterminate']) {
		background: var(--accent);
		border-color: var(--accent);
	}

	/* ---- footer ---- */
	.table-wrap .tfoot {
		display: flex;
		align-items: center;
		gap: 14px;
		padding: 12px 14px;
		border-top: 1px solid var(--border);
		font-size: 12.5px;
		color: var(--text-2);
	}

	.table-wrap .tfoot .sp {
		flex: 1;
	}

	/* ---- rows-per-page selector (footer) ---- */
	.table-wrap .rows-per-page {
		display: inline-flex;
		align-items: center;
		gap: 7px;
	}

	.table-wrap .rows-per-page select {
		height: 28px;
		padding: 0 6px;
		font-family: var(--font-mono);
		font-size: 12.5px;
		color: var(--text);
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-sm);
		cursor: pointer;
	}

	.table-wrap .rows-per-page select:hover {
		border-color: var(--text-3);
	}

	/* ---- row name / subtitle pattern ---- */
	.table-wrap .row-name {
		display: flex;
		align-items: center;
		gap: 9px;
	}

	/* ---- empty state ---- */
	.table-wrap tbody tr.row-empty td {
		padding: 32px 14px;
		text-align: center;
		color: var(--text-3);
		font-size: 13px;
	}

	/* ---- loading / error states ---- */
	.table-wrap .table-loading {
		padding: 32px 14px;
		text-align: center;
		color: var(--text-3);
		font-size: 13px;
	}

	.table-wrap .table-error {
		padding: 12px 14px;
		color: var(--danger);
		font-size: 13px;
		background: var(--danger-weak);
		border-bottom: 1px solid var(--border);
	}

	.table-wrap .row-sub {
		color: var(--text-3);
		font-size: 11.5px;
	}

	/* ---- schema-aware default cell rendering ----
	   Blank, number, and date cells render through the shared FieldValue
	   primitive; the enum pill and the boolean cell stay table-owned via the
	   consumer snippets passed to FieldValue. */
	.table-wrap .cell-enum {
		display: inline-flex;
		align-items: center;
		gap: 6px;
		padding: 2px 10px;
		border-radius: var(--r-pill);
		font-size: 11.5px;
		font-weight: 600;
		line-height: 1.4;
		white-space: nowrap;
	}

	.table-wrap .cell-enum-dot {
		width: 6px;
		height: 6px;
		border-radius: 50%;
		flex-shrink: 0;
	}

	.table-wrap .cell-bool {
		display: inline-flex;
		align-items: center;
		justify-content: center;
		width: 18px;
		height: 18px;
		border-radius: var(--r-sm);
		font-family: var(--font-mono);
		font-size: 12px;
		font-weight: 600;
		line-height: 1;
		color: var(--danger);
		background: var(--danger-weak);
	}

	.table-wrap .cell-bool.on {
		color: var(--ok);
		background: var(--ok-weak);
	}

	.table-wrap button.cell-bool {
		border: none;
		padding: 0;
		cursor: pointer;
	}

	.table-wrap button.cell-bool:hover:not(:disabled) {
		box-shadow: 0 0 0 2px var(--border-strong);
	}

	.table-wrap button.cell-bool:focus-visible {
		outline: 2px solid var(--accent);
		outline-offset: 1px;
	}

	.table-wrap button.cell-bool:disabled {
		opacity: 0.55;
		cursor: default;
	}
</style>
