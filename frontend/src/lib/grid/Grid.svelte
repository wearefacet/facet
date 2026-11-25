<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<!--
	The grid listing surface (`surface: grid`) — the listing as a spreadsheet.

	One row per document, one column per field, no free cells. The component
	mirrors the `Table`'s data machinery (toolbar, capped count, pagination,
	schema-aware cells) and adds the spreadsheet layer: an active cell with a
	shift-extendable range, keyboard navigation, TSV copy, sticky frozen
	columns, and the Σ row of server aggregates.

	Editing (the editors phase): a writable column over a writable field,
	under the viewer's `update` grant, opens the per-type cell editor —
	Enter / F2 / double-click on the value, a typed char replaces it. Booleans
	flip in place with no edit mode. Writes go through the per-row write
	queue (one PATCH per row, cap 4) with a session undo stack (⌘Z). A
	rejected cell keeps the typed text under a local error state — Esc
	reverts; a 403 reverts, toasts, and locks the row read-only for the
	session. A refetch re-applies in-flight cell values and leaves the open
	editor open.
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
	import { toast } from '$lib/toast.svelte.js';
	import { can } from '$lib/permissions.svelte';
	import { DataSourceError } from '$lib/datasource/types.js';
	import type { DocumentResponse } from '$lib/datasource/types.js';
	import { createSelection } from './selection.svelte.js';
	import { cellCopyText, serializeTSV } from './clipboard.js';
	import { fetchSummaries, type FieldSummary } from './summary.js';
	import { createWriteQueue } from './writeQueue.js';
	import { valueEquals } from './coerce.js';
	import { WRITABLE_FIELD_TYPES } from './fieldTypes.js';
	import CellEditor from './editors/CellEditor.svelte';
	import type { CommitMove } from './editors/types.js';
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
			// The re-query never clobbers a cell in flight or under a local
			// error: the pending values re-apply on top of the refreshed rows,
			// and the open editor stays open (its draft is its own).
			if (pending.size > 0) {
				const reapply = new Map<string, Map<string, CellPending>>();
				for (const [rowId, inner] of pending) reapply.set(rowId, new Map(inner));
				items = items.map((row) => {
					const rowId = rowKey(row);
					const inner = reapply.get(rowId);
					if (!inner) return row;
					const next = { ...(row as Record<string, unknown>) };
					for (const [key, entry] of inner) next[key] = entry.value;
					return next as T;
				});
			}
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

	/** A primary press started on a grid cell or gutter and is still down.
	 *  Only it arms the drag-select (see `cellMouseEnter`). */
	let pressArmed = false;

	const maxRow = $derived(items.length - 1);
	const maxCol = $derived(columns.length - 1);

	/** The row item the focus cell sits on — Enter/Space open its peek. */
	const focusItem = $derived.by<T | null>(() => {
		const focus = selection.focus;
		if (!focus || items.length === 0) return null;
		return items[Math.min(focus.row, items.length - 1)] ?? null;
	});

	function cellMouseDown(r: number, c: number, e: MouseEvent) {
		// The press keeps its focus inside the grid: the browser default would
		// park it on the pressed inner control (a reference capsule, the
		// boolean toggle), and the next keyboard move would light the
		// user-agent focus ring there while the selection ring sits elsewhere.
		e.preventDefault();
		// A mousedown on another cell commits the open editor first — the
		// spreadsheet norm. An unparseable draft cancels instead.
		if (editing && (editing.r !== r || editing.c !== c)) {
			editorApi?.commitFromOutside();
		}
		// This press arms the drag-select — a press inside the open editor
		// never reaches here (the editor's shell stops it).
		pressArmed = true;
		if (e.shiftKey) {
			selection.extendTo(r, c, maxRow, maxCol);
		} else {
			selection.setFocus(r, c, maxRow, maxCol);
		}
		refocusCell(r, c);
	}

	/** Drag-select: the primary button is already down, hovering extends.
	 *  Only a press that started on the grid's own cells may drag — the enum
		list closes its editor under the held button, and the cells exposed
		underneath must not sweep-select. */
	function cellMouseEnter(r: number, c: number, e: MouseEvent) {
		if (!pressArmed) return;
		if ((e.buttons & 1) === 0) return;
		if (e.shiftKey) return;
		selection.extendTo(r, c, maxRow, maxCol);
	}

	/** Gutter click selects the whole row (all data columns of the row). */
	function gutterMouseDown(r: number, e: MouseEvent) {
		if (maxCol < 0) return;
		if (editing) editorApi?.commitFromOutside();
		pressArmed = true;
		if (e.shiftKey && selRange) {
			selection.extendTo(r, maxCol, maxRow, maxCol);
		} else {
			selection.setFocus(r, 0, maxRow, maxCol);
			selection.extendTo(r, maxCol, maxRow, maxCol);
		}
	}

	// ── Cell editing (the editors phase) ─────────────────────────────────

	/** The open editor: its row, column, and the seed char (type-to-edit). */
	let editing = $state<{ r: number; c: number; seed: string | null } | null>(null);
	/** The open shell's API — the outside-commit request goes through it. */
	let editorApi: { commitFromOutside(): void } | null = $state(null);
	/** The scrolling frame — cell focus restore looks cells up here. */
	let gridEl: HTMLElement | null = $state(null);

	/** Per-cell write state, keyed rowId → colKey. `saving` dims the cell;
	 *  `error` keeps the typed text under an error frame — Esc reverts. */
	interface CellPending {
		status: 'saving' | 'error';
		value: unknown;
		/** The pre-write value — the Esc revert of a failed cell. */
		before?: unknown;
		/** The failure message (the 422's text) — the cell's tooltip. */
		message?: string;
	}
	let pending = $state<Map<string, Map<string, CellPending>>>(new Map());
	/** Rows the session locks read-only after a 403 — the backend denied the
	 *  write; the UI stops offering it. */
	let lockedRows = $state<Set<string>>(new Set());

	/** One PATCH per row, at most 4 rows in flight, undo entries recorded
	 *  from the `before` diffs the callers pass. */
	const writeQueue = createWriteQueue((rowId, diff) => datasource.doc(rowId).update(diff));

	function pendingFor(rowId: string, key: string): CellPending | undefined {
		return pending.get(rowId)?.get(key);
	}

	function setPending(rowId: string, key: string, entry: CellPending | null): void {
		const outer = new Map(pending);
		if (entry == null) {
			const inner = outer.get(rowId);
			if (!inner) return;
			const next = new Map(inner);
			next.delete(key);
			if (next.size === 0) outer.delete(rowId);
			else outer.set(rowId, next);
		} else {
			const next = new Map(outer.get(rowId) ?? new Map<string, CellPending>());
			next.set(key, entry);
			outer.set(rowId, next);
		}
		pending = outer;
	}

	/** Rows with a write in flight — their computed (`data`) cells dim. */
	const savingRows = $derived.by(() => {
		const set = new Set<string>();
		for (const [rowId, inner] of pending) {
			for (const entry of inner.values()) {
				if (entry.status === 'saving') {
					set.add(rowId);
					break;
				}
			}
		}
		return set;
	});

	/** Whether the column's field is writable at all — the column flag
	 *  (`editable: false`) and the system timestamp columns also gate. */
	function colEditable(col: GridColumn): boolean {
		if (col.editable === false) return false;
		if (!doctype || SYSTEM_TS_KEYS.has(col.key)) return false;
		const field = fieldFor(col);
		if (!field) return false;
		if (field.read_only || field.write_only) return false;
		if (!WRITABLE_FIELD_TYPES.has(field.type)) return false;
		return can(`${doctype.domain}.${doctype.doctype}`, 'update');
	}

	/** Per-cell editability — the column gate plus the row's 403 lock. */
	function cellWritable(item: T, col: GridColumn): boolean {
		if (!colEditable(col)) return false;
		return !lockedRows.has(rowKey(item));
	}

	function openEditor(seed: string | null): void {
		const focus = selection.focus;
		if (!focus || editing) return;
		const col = columns[focus.col];
		const item = items[focus.row];
		if (!col || !item) return;
		if (fieldFor(col)?.type === 'boolean') return; // booleans have no edit mode
		if (!cellWritable(item, col)) return;
		editing = { r: focus.row, c: focus.col, seed };
	}

	function closeEditor(): void {
		editing = null;
	}

	/** Set one cell in the row store — the optimistic apply and the revert. */
	function applyCell(rowId: string, key: string, value: unknown, updatedAt?: string): void {
		items = items.map((row) => {
			if (rowKey(row) !== rowId) return row;
			const next = { ...(row as Record<string, unknown>), [key]: value };
			if (updatedAt != null) next.updated_at = updatedAt;
			return next as T;
		});
	}

	/**
	 * Write one cell: optimistic apply, one queued PATCH, then the response
	 * settles it. A 403 reverts, toasts, and locks the row for the session;
	 * any other failure (422, network) keeps the typed value on the cell
	 * under the error state — Esc reverts.
	 */
	async function commitCell(r: number, c: number, value: unknown): Promise<void> {
		const col = columns[c];
		const item = items[r];
		if (!col || !item) return;
		const rowId = rowKey(item);
		const before = (item as Record<string, unknown>)[col.key];
		if (valueEquals(before, value)) return; // a no-op never PATCHes
		applyCell(rowId, col.key, value);
		setPending(rowId, col.key, { status: 'saving', value });
		try {
			const saved = (await writeQueue.push(
				rowId,
				{ [col.key]: value },
				{
					before: { [col.key]: before }
				}
			)) as DocumentResponse<T> | undefined;
			setPending(rowId, col.key, null);
			if (saved?.meta) {
				applyCell(rowId, col.key, value, saved.meta.updated_at);
				// Computed columns refresh from the PATCH response — the
				// backend recomputed them server-side on this write.
				const content = saved.data as Record<string, unknown> | undefined;
				if (doctype && content) {
					for (const field of doctype.fields) {
						if (field.type === 'data' && field.key in content) {
							applyCell(rowId, field.key, content[field.key]);
						}
					}
				}
			}
		} catch (err) {
			if (err instanceof DataSourceError && err.status === 403) {
				setPending(rowId, col.key, null);
				applyCell(rowId, col.key, before);
				const next = new Set(lockedRows);
				next.add(rowId);
				lockedRows = next;
				toast({ message: errorMessage(err, m.common_save_failed()), variant: 'error' });
			} else {
				setPending(rowId, col.key, {
					status: 'error',
					value,
					before,
					message: errorMessage(err, m.common_save_failed())
				});
			}
		}
	}

	/** Booleans have no edit mode — the flip IS the write (the Table's
	 *  inline toggle, generalized through the queue). */
	function flipBoolean(r: number, c: number): void {
		const col = columns[c];
		const item = items[r];
		if (!col || !item || !cellWritable(item, col)) return;
		if (fieldFor(col)?.type !== 'boolean') return;
		const current = (item as Record<string, unknown>)[col.key];
		void commitCell(r, c, current !== true);
	}

	/** ⌘Z — invert the newest committed op. Cells the row no longer carries
	 *  (changed since) skip; the rest reverts through the queue, unrecorded. */
	async function undoLast(): Promise<void> {
		const entry = writeQueue.popUndo();
		if (!entry) return;
		const r = items.findIndex((row) => rowKey(row) === entry.rowId);
		if (r < 0) return;
		const row = items[r] as Record<string, unknown>;
		let skipped = false;
		for (const [key, after] of Object.entries(entry.after)) {
			if (!valueEquals(row[key], after)) skipped = true;
		}
		if (skipped) {
			toast({ message: m.grid_undo_skipped(), variant: 'error' });
		}
		for (const [key, after] of Object.entries(entry.after)) {
			if (!valueEquals(row[key], after)) continue;
			const c = columns.findIndex((col) => col.key === key);
			if (c >= 0) await commitCell(r, c, entry.before[key]);
		}
	}

	/** The editor's commit — close, write, then move as the key asked. A
	 *  keyboard commit refocuses a cell: the unmounting input drops focus
	 *  to the body, and the next chord (⌘Z, Esc) must still reach the grid. */
	function handleEditorCommit(value: unknown, move: CommitMove): void {
		const current = editing;
		closeEditor();
		if (!current) return;
		void commitCell(current.r, current.c, value);
		if (move === 'down') selection.move(1, 0, false, maxRow, maxCol);
		else if (move === 'right') selection.move(0, 1, false, maxRow, maxCol);
		if (move != null) {
			const f = selection.focus;
			if (f) refocusCell(f.row, f.col);
		} else {
			// A pointer commit (a pick in the open enum list, the outside
			// commit) carries no move — the unmounting input would drop focus
			// to the body and the next chord would miss the grid.
			refocusCell(current.r, current.c);
		}
	}

	function handleEditorCancel(): void {
		const current = editing;
		closeEditor();
		if (current) refocusCell(current.r, current.c);
	}

	/** Put the DOM focus back on a cell — the keyboard lives there. False
	 *  when the cell is gone (a refetch shrank the page). */
	function refocusCell(r: number, c: number): boolean {
		const el = gridEl?.querySelector<HTMLElement>(`[data-row="${r}"][data-col="${c}"]`);
		if (!el) return false;
		el.focus();
		return true;
	}

	/** A keyboard move carries the DOM focus to the new focus cell — the
	 *  selection ring and the focused element never disagree, and the view
	 *  follows the move. A gone cell falls back to the container so the
	 *  next keypress still reaches the grid. */
	function focusAfterMove(): void {
		const f = selection.focus;
		if (!f) return;
		if (!refocusCell(f.row, f.col)) gridEl?.focus();
	}

	/** A failed cell's Esc — drop the typed value, restore the pre-write
	 *  one. Every error cell reverts: the commit moved the selection, so
	 *  the failed cell is usually not the focused one. */
	function revertErrorCells(): void {
		if (pending.size === 0) return;
		const reverts: { rowId: string; key: string; before: unknown }[] = [];
		for (const [rowId, inner] of pending) {
			for (const [key, entry] of inner) {
				if (entry.status === 'error') {
					reverts.push({ rowId, key, before: entry.before });
				}
			}
		}
		for (const rev of reverts) {
			applyCell(rev.rowId, rev.key, rev.before);
			setPending(rev.rowId, rev.key, null);
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
		// Undo — the session stack's inverse PATCH. No redo.
		if ((e.metaKey || e.ctrlKey) && (key === 'z' || key === 'Z')) {
			e.preventDefault();
			void undoLast();
			return;
		}
		if (e.metaKey || e.ctrlKey || e.altKey) return;
		const extend = e.shiftKey && key.startsWith('Arrow');
		const focus = selection.focus;
		const focusCol = focus != null ? columns[focus.col] : undefined;
		const focusRowItem = focus != null ? items[focus.row] : undefined;
		switch (key) {
			case 'ArrowDown':
				e.preventDefault();
				selection.move(1, 0, extend, maxRow, maxCol);
				focusAfterMove();
				break;
			case 'ArrowUp':
				e.preventDefault();
				selection.move(-1, 0, extend, maxRow, maxCol);
				focusAfterMove();
				break;
			case 'ArrowRight':
				e.preventDefault();
				selection.move(0, 1, extend, maxRow, maxCol);
				focusAfterMove();
				break;
			case 'ArrowLeft':
				e.preventDefault();
				selection.move(0, -1, extend, maxRow, maxCol);
				focusAfterMove();
				break;
			case 'Home':
				e.preventDefault();
				selection.setFocus(0, 0, maxRow, maxCol);
				focusAfterMove();
				break;
			case 'End':
				e.preventDefault();
				selection.setFocus(maxRow, 0, maxRow, maxCol);
				focusAfterMove();
				break;
			case 'Enter':
				// Editing takes Enter over on a writable cell; elsewhere it
				// keeps opening the row like the table's Enter does.
				if (
					focus &&
					focusCol &&
					focusRowItem &&
					cellWritable(focusRowItem, focusCol) &&
					fieldFor(focusCol)?.type !== 'boolean'
				) {
					e.preventDefault();
					openEditor(null);
				} else if (focusItem && onRowClick) {
					e.preventDefault();
					onRowClick(focusItem);
				}
				break;
			case 'F2':
				e.preventDefault();
				openEditor(null);
				break;
			case ' ':
				// Space flips a writable boolean in place; elsewhere it opens
				// the peek drawer (the object types' only affordance).
				if (
					focus &&
					focusCol &&
					focusRowItem &&
					cellWritable(focusRowItem, focusCol) &&
					fieldFor(focusCol)?.type === 'boolean'
				) {
					e.preventDefault();
					flipBoolean(focus.row, focus.col);
				} else if (focusItem && onRowClick) {
					e.preventDefault();
					onRowClick(focusItem);
				}
				break;
			case 'Escape':
				// A failed cell reverts first; the next Escape clears the range.
				revertErrorCells();
				selection.clear();
				break;
			default:
				// A printable char starts the editor with that char — the
				// spreadsheet's type-to-replace. Booleans have no edit mode.
				if (
					key.length === 1 &&
					focus &&
					focusCol &&
					focusRowItem &&
					cellWritable(focusRowItem, focusCol) &&
					fieldFor(focusCol)?.type !== 'boolean'
				) {
					e.preventDefault();
					openEditor(key);
				}
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

<!-- The press ends wherever the pointer is — the drag disarms globally. -->
<svelte:window onmouseup={() => (pressArmed = false)} />

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
			bind:this={gridEl}
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
							onmousedown={(e) => {
								// Same rule as the data cells — the checkbox never keeps
								// the pointer's focus; the cell takes it.
								e.preventDefault();
								e.currentTarget.focus();
							}}
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
						{@const cellEntry = pendingFor(rowKey(item), col.key)}
						{@const isEditing = editing?.r === r && editing?.c === c}
						<div
							class="g-cell {colAlign(col)}"
							class:frozen={sticky != null}
							class:frozen-last={frozenLast}
							class:in-range={inRange && !isFocus}
							class:focused={isFocus}
							class:computed={isComputed(col)}
							class:saving={cellEntry?.status === 'saving'}
							class:cell-error={cellEntry?.status === 'error'}
							class:stale={isComputed(col) && savingRows.has(rowKey(item))}
							class:editing={isEditing}
							style={sticky != null ? `left: ${sticky}px` : ''}
							role="gridcell"
							tabindex="-1"
							aria-selected={inRange}
							aria-colindex={c + 1}
							data-row={r}
							data-col={c}
							title={cellEntry?.status === 'error' ? cellEntry.message : undefined}
							onmousedown={(e) => cellMouseDown(r, c, e)}
							onmouseenter={(e) => cellMouseEnter(r, c, e)}
							ondblclick={() => openEditor(null)}
						>
							{#if isEditing}
								<CellEditor
									field={fieldFor(col)!}
									label={col.label}
									value={(item as Record<string, unknown>)[col.key]}
									seed={editing!.seed}
									{driver}
									oncommit={handleEditorCommit}
									oncancel={handleEditorCancel}
									bind:this={editorApi}
								/>
							{:else}
								{@render dataCell(item, col, r, c)}
							{/if}
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

{#snippet dataCell(item: T, col: GridColumn, r: number, c: number)}
	{@const value = (item as Record<string, unknown>)[col.key]}
	{@const field = fieldFor(col)}
	{@const writable = cellWritable(item, col)}
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
			{#if writable}
				<!-- The Table's inline toggle, generalized: the flip IS the
					write — no edit mode, one queued PATCH, optimistic. -->
				<button
					type="button"
					class="cell-bool"
					class:on={v === true}
					aria-pressed={v === true}
					aria-label={m.table_bool_toggle_aria({ field: col.label ?? col.key })}
					title={m.table_bool_toggle_aria({ field: col.label ?? col.key })}
					disabled={pendingFor(rowKey(item), col.key)?.status === 'saving'}
					onclick={() => flipBoolean(r, c)}
				>
					{v === true ? '✓' : '✕'}
				</button>
			{:else}
				<span class="cell-bool" class:on={v === true} title={String(v)}>
					{v === true ? '✓' : '✕'}
				</span>
			{/if}
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

	/* The grid paints its own focus indicator (the `focused` ring above).
	   The user-agent outline would add a second ring — on the focused cell,
	   or on whatever inner control an earlier press left focused — and that
	   UA ring only paints while the window is focused, so it reads as a
	   stray highlight that comes and goes. */
	.g-cell:focus-visible {
		outline: none;
	}

	.g-cell.computed {
		color: var(--text-2);
	}

	/* ── Editing states ── */

	/* A cell with a write in flight dims — the value is not settled yet. */
	.g-cell.saving {
		opacity: 0.55;
	}

	/* A rejected cell keeps the typed value under an error frame; the
		tooltip (the cell's title) carries the 422's message. */
	.g-cell.cell-error {
		box-shadow: inset 0 0 0 2px var(--danger);
	}

	/* Computed cells dim while a source cell in their row saves — the value
		they show is about to go stale; the PATCH response refreshes it. */
	.g-cell.stale {
		opacity: 0.45;
	}

	/* The open editor: the cell stops clipping so the pickers' panels show,
		and the frame rises above the frozen columns. */
	.g-cell.editing {
		overflow: visible;
		z-index: 20;
	}

	.g-cell.editing.frozen {
		z-index: 20;
	}

	/* Writable booleans read as buttons — the flip is one click. */
	button.cell-bool {
		cursor: pointer;
		border: 0;
		background: none;
		font: inherit;
		padding: 0;
	}

	button.cell-bool:disabled {
		cursor: default;
		opacity: 0.6;
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
