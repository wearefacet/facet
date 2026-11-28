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
	import { tick } from 'svelte';
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
	import { displayTimezone } from '$lib/settings.svelte';
	import { DataSourceError } from '$lib/datasource/types.js';
	import type { DocumentResponse } from '$lib/datasource/types.js';
	import { createSelection } from './selection.svelte.js';
	import { cellCopyText, parseTSV, serializeTSV } from './clipboard.js';
	import { fetchSummaries, type FieldSummary } from './summary.js';
	import { createWriteQueue } from './writeQueue.js';
	import { valueEquals, coercePaste } from './coerce.js';
	import { WRITABLE_FIELD_TYPES } from './fieldTypes.js';
	import { missingRequired, newRowBody, newRowDefaults, draftDirty } from './newRow.js';
	import { placeFloater } from './floatPlacement.js';
	import { renderValidationError } from '$lib/datasource/validationMessages.js';
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
		toolbarActions = undefined,
		allowCreate = false
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
			// A refetch that shrank the data pulls the selection back in bounds
			// (the ghost row counts as a bound when the new-row line is on).
			selection.clampTo(canCreateRow ? items.length : items.length - 1, columns.length - 1);
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

	/** The row item the focus cell sits on — Enter/Space open its peek.
	 *  `null` on the ghost row: a pending new row has nothing to peek. */
	const focusItem = $derived.by<T | null>(() => {
		const focus = selection.focus;
		if (!focus || items.length === 0) return null;
		if (focus.row >= items.length) return null;
		return items[focus.row] ?? null;
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
			selection.extendTo(r, c, navMaxRow, maxCol);
		} else {
			selection.setFocus(r, c, navMaxRow, maxCol);
		}
		refocusCell(r, c);
	}

	/** Drag-select: the primary button is already down, hovering extends.
	 *  Only a press that started on the grid's own cells may drag — the enum
		list closes its editor under the held button, and the cells exposed
		underneath must not sweep-select. */
	function cellMouseEnter(r: number, c: number, e: MouseEvent) {
		tipHover = { r, c };
		if (!pressArmed) return;
		if ((e.buttons & 1) === 0) return;
		if (e.shiftKey) return;
		selection.extendTo(r, c, navMaxRow, maxCol);
	}

	/** The pointer left the cell — its hover-held failure label drops. */
	function cellMouseLeave(r: number, c: number): void {
		if (tipHover && tipHover.r === r && tipHover.c === c) tipHover = null;
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
	 *  `error` keeps the typed text under an error frame — Esc reverts. A
	 *  paste mark carries a `mark` token and fades out on a timer; a write
	 *  error (422) carries none and stays until Esc or a newer write. */
	interface CellPending {
		status: 'saving' | 'error';
		value: unknown;
		/** The pre-write value — the Esc revert of a failed cell. */
		before?: unknown;
		/** The failure message (the 422's text) — the cell's tooltip. */
		message?: string;
		/** The paste-mark token the fade schedule keys off. */
		mark?: number;
		/** The mark's fade phase — the CSS eases the frame out. */
		fading?: boolean;
	}
	let pending = $state<Map<string, Map<string, CellPending>>>(new Map());
	/** Rows the session locks read-only after a 403 — the backend denied the
	 *  write; the UI stops offering it. */
	let lockedRows = $state<Set<string>>(new Set());

	/** One PATCH per row, at most 4 rows in flight, undo entries recorded
	 *  from the `before` diffs the callers pass. */
	const writeQueue = createWriteQueue((rowId, diff) => datasource.doc(rowId).update(diff));

	/** The user-gesture counter — one gesture (a cell commit, a flip, a
	 *  whole pasted block) shares one action id, the undo unit's identity. */
	let actionSeq = 0;

	// ── The ghost new-row line (`allow_create`) ─────────────────────

	/** The qualified doctype id the `create` grant reads. */
	const qualifiedName = $derived(doctype ? `${doctype.domain}.${doctype.doctype}` : '');

	/** A 403 on a create locks the line off for the session — the row-403
	 *  contract (revert, toast, lock). */
	let createLocked = $state(false);

	/** The ghost row's own grant chain: the view opts in, the schema is
	 *  loaded, the viewer holds the flat `create` grant, and no 403 locked
	 *  it off. */
	const canCreateRow = $derived(
		allowCreate && doctype !== undefined && !createLocked && can(qualifiedName, 'create')
	);

	/** The ghost row's index in the selection space — one past the data. */
	const newRow = $derived(canCreateRow ? items.length : -1);

	/** The navigation bounds include the ghost row; copy/paste keep the
	 *  real-data bounds (nothing to copy, nothing to PATCH there). */
	const navMaxRow = $derived(canCreateRow ? items.length : maxRow);

	/** The new-row draft — only committed user values. Declared defaults
	 *  never enter it: they preview from the schema and the server fills
	 *  them at create time. */
	let newDraft = $state<Record<string, unknown>>({});

	/** The rejected create's per-cell messages, keyed by column key — the
	 *  invalid state that holds until the value is fixed or Esc clears the
	 *  draft. */
	let newErrors = $state<Map<string, string>>(new Map());

	/** A create is in flight — the row dims; commits stage into the draft. */
	let creating = $state(false);

	/** The writable columns' declared defaults — the ghost row's preview. */
	const newDefaults = $derived(
		canCreateRow && doctype ? newRowDefaults(columns, doctype.fields) : {}
	);

	/** The required-no-default fields the draft still misses (column-backed
	 *  ones — the client gate's only honest scope). */
	const newMissingKeys = $derived.by<Set<string>>(() => {
		if (!canCreateRow || !doctype) return new Set();
		return new Set(missingRequired(newDraft, columns, doctype.fields).map((f) => f.key));
	});

	const newDirty = $derived(canCreateRow && draftDirty(newDraft));

	/** The first writable column — the clean row's prompt sits there. */
	const newPromptCol = $derived.by<number>(() => {
		for (let c = 0; c < columns.length; c++) {
			if (newCellWritable(columns[c])) return c;
		}
		return -1;
	});

	/** The ghost row's per-column writability — the column flag plus the
	 *  field gates. The row's grant is the viewer's `create`, not `update`
	 *  (a create-only role still types the new-row line). */
	function newCellWritable(col: GridColumn): boolean {
		if (!doctype || col.editable === false) return false;
		if (SYSTEM_TS_KEYS.has(col.key)) return false;
		const field = fieldFor(col);
		if (!field || field.read_only || field.write_only) return false;
		return WRITABLE_FIELD_TYPES.has(field.type);
	}

	/** The value a ghost cell previews — the committed draft value, else
	 *  the declared default. An explicitly cleared cell shows empty: the
	 *  body omits the key, so the server refills the default on create. */
	function newCellValue(key: string): unknown {
		if (key in newDraft) return newDraft[key];
		return newDefaults[key];
	}

	/** Where a ghost commit sends the selection: Tab walks right, Enter
	 *  stays (the clamp holds the row — Excel's wrap needs a row below
	 *  that does not exist yet). */
	function moveAfterNewRowCommit(c: number, move: CommitMove, targetRow: number): void {
		const nextCol = move === 'right' ? Math.min(maxCol, c + 1) : c;
		selection.setFocus(targetRow, nextCol, targetRow, maxCol);
		const f = selection.focus;
		if (f) refocusCell(f.row, f.col);
	}

	/**
	 * One ghost cell's commit — stage into the draft, then create as soon
	 * as the client gate passes. A blocked create (required fields still
	 * missing) stays silent after the first heads-up: the missing cells
	 * carry the inline hint. A refused create (422) keeps the draft under
	 * error frames — the invalid state holds until the value is fixed (the
	 * next commit retries) or Esc clears the draft. A 403 reverts the draft
	 * and locks the line off for the session.
	 */
	async function commitNewRowCell(c: number, value: unknown, move: CommitMove): Promise<void> {
		const col = columns[c];
		if (!col || !doctype) return;
		const wasDirty = newDirty;
		const next = { ...newDraft };
		if (value === null || value === '') delete next[col.key];
		else next[col.key] = value;
		newDraft = next;
		// A fresh value replaces a failed one — the paste's stale-frame rule.
		if (newErrors.has(col.key)) {
			const cleared = new Map(newErrors);
			cleared.delete(col.key);
			newErrors = cleared;
		}

		const missing = missingRequired(newDraft, columns, doctype.fields);
		if (missing.length > 0) {
			// One heads-up when the row first blocks; the inline hints on the
			// missing cells carry the rest (a toast per commit is noise).
			if (!wasDirty) {
				toast({ message: m.grid_new_row_fill({ field: missing[0].title ?? missing[0].key }) });
			}
			moveAfterNewRowCommit(c, move, newRow);
			return;
		}

		const body = newRowBody(newDraft);
		if (Object.keys(body).length === 0) {
			moveAfterNewRowCommit(c, move, newRow);
			return;
		}
		// One create at a time: a commit that lands while one flies only
		// stages — on success the delta PATCH carries it onto the created
		// row; on failure the draft keeps it for the next attempt.
		if (creating) {
			moveAfterNewRowCommit(c, move, newRow);
			return;
		}

		creating = true;
		const action = ++actionSeq;
		try {
			const saved = await datasource.create(body as T);
			// Flatten the created projection onto the row shape, the same
			// fold `loadData` applies to list items.
			const meta = saved.meta;
			const createdRow = {
				id: meta.id,
				created_at: meta.created_at,
				updated_at: meta.updated_at,
				...saved.data
			} as T;
			// The values typed while the create flew stage onto the created
			// row through the normal write path (undo-able, one gesture).
			const delta: Record<string, unknown> = {};
			for (const [key, value] of Object.entries(newDraft)) {
				if (!valueEquals(body[key], value)) delta[key] = value;
			}
			creating = false;
			newDraft = {};
			newErrors = new Map();
			items = [...items, createdRow];
			const r = items.length - 1;
			if (Object.keys(delta).length > 0) void commitDiff(r, delta, action);
			void loadData();
			// Excel's rhythm: the fresh ghost row below takes the selection.
			// The tick lets the appended row render first — the refocus
			// queries the DOM for the moved-ghost cell.
			void tick().then(() => moveAfterNewRowCommit(c, move, items.length));
		} catch (err) {
			creating = false;
			if (err instanceof DataSourceError && err.status === 403) {
				newDraft = {};
				newErrors = new Map();
				createLocked = true;
				toast({ message: errorMessage(err, m.common_save_failed()), variant: 'error' });
				return;
			}
			// The refused create keeps the draft on the row: the cells the 422
			// details name take the error frame; the committed cell falls back
			// when the failure has no usable field list (the invalid state).
			const marks = new Map<string, string>();
			const details = err instanceof DataSourceError ? err.details : undefined;
			if (details) {
				for (const detail of details) {
					if (!detail.field) continue;
					const key = detail.field.split('.')[0];
					if (columns.some((column) => column.key === key)) {
						marks.set(key, renderValidationError(detail));
					}
				}
			}
			if (marks.size === 0) marks.set(col.key, errorMessage(err, m.common_save_failed()));
			newErrors = marks;
			toast({ message: errorMessage(err, m.common_save_failed()), variant: 'error' });
			moveAfterNewRowCommit(c, move, newRow);
		}
	}

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

	/** Rows with a failed write — their gutter reads danger while the
	 *  failing cells carry the frames. */
	const errorRows = $derived.by(() => {
		const set = new Set<string>();
		for (const [rowId, inner] of pending) {
			for (const entry of inner.values()) {
				if (entry.status === 'error') {
					set.add(rowId);
					break;
				}
			}
		}
		return set;
	});

	/** The first failed cell's message — the gutter tooltip's text. */
	function rowErrorTitle(rowId: string): string | undefined {
		const inner = pending.get(rowId);
		if (!inner) return undefined;
		for (const entry of inner.values()) {
			if (entry.status === 'error') return entry.message;
		}
		return undefined;
	}

	/** The failure label's pointer position — the hovered cell. The label
	 *  shows only under the pointer: it appears when the pointer enters the
	 *  failing cell and drops the moment it leaves (the frame stays). */
	let tipHover = $state<{ r: number; c: number } | null>(null);

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
		if (!col) return;
		if (focus.row === newRow) {
			// The ghost row: writable non-boolean columns take the editor —
			// the row's grant is `create`, not `update`.
			if (fieldFor(col)?.type === 'boolean') return;
			if (!newCellWritable(col)) return;
			editing = { r: focus.row, c: focus.col, seed };
			return;
		}
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
	 * Write one row's cells: optimistic apply, one queued PATCH carrying the
	 * whole diff, then the response settles it. A 403 reverts the row, toasts,
	 * and locks it for the session; any other failure (422, network) keeps the
	 * written values on the cells under the error state — Esc reverts. Keys
	 * whose value already matches the row drop — a no-op never PATCHes.
	 * `action` marks a user gesture: the resolved write records an undo
	 * entry under it. Undo and redo writes omit it — they never record.
	 */
	async function commitDiff(
		r: number,
		changes: Record<string, unknown>,
		action?: number
	): Promise<void> {
		const item = items[r];
		if (!item) return;
		const rowId = rowKey(item);
		const record = item as Record<string, unknown>;
		const effective: Record<string, unknown> = {};
		const before: Record<string, unknown> = {};
		for (const [key, value] of Object.entries(changes)) {
			const current = record[key];
			if (valueEquals(current, value)) continue;
			effective[key] = value;
			before[key] = current;
		}
		if (Object.keys(effective).length === 0) return;
		for (const key of Object.keys(effective)) {
			applyCell(rowId, key, effective[key]);
			setPending(rowId, key, { status: 'saving', value: effective[key] });
		}
		try {
			const saved = (await writeQueue.push(rowId, effective, { before, action })) as
				| DocumentResponse<T>
				| undefined;
			for (const key of Object.keys(effective)) setPending(rowId, key, null);
			if (saved?.meta) {
				for (const key of Object.keys(effective)) {
					applyCell(rowId, key, effective[key], saved.meta.updated_at);
				}
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
				for (const key of Object.keys(effective)) {
					setPending(rowId, key, null);
					applyCell(rowId, key, before[key]);
				}
				const next = new Set(lockedRows);
				next.add(rowId);
				lockedRows = next;
				toast({ message: errorMessage(err, m.common_save_failed()), variant: 'error' });
			} else {
				// The cells the 422 details name speak through the validation
				// catalogue (the create path's rule); the other written cells
				// keep the generic failure text — nothing on the PATCH landed.
				const details = err instanceof DataSourceError ? err.details : undefined;
				const marks = new Map<string, string>();
				if (details) {
					for (const detail of details) {
						if (!detail.field) continue;
						const key = detail.field.split('.')[0];
						if (key in effective && columns.some((column) => column.key === key)) {
							marks.set(key, renderValidationError(detail));
						}
					}
				}
				const fallback = errorMessage(err, m.common_save_failed());
				for (const key of Object.keys(effective)) {
					setPending(rowId, key, {
						status: 'error',
						value: effective[key],
						before: before[key],
						message: marks.get(key) ?? fallback
					});
				}
			}
		}
	}

	/** One cell of a row — the editors' path onto the shared diff write. */
	async function commitCell(r: number, c: number, value: unknown, action?: number): Promise<void> {
		const col = columns[c];
		if (!col) return;
		await commitDiff(r, { [col.key]: value }, action);
	}

	/** Booleans have no edit mode — the flip IS the write (the Table's
	 *  inline toggle, generalized through the queue). */
	function flipBoolean(r: number, c: number): void {
		const col = columns[c];
		const item = items[r];
		if (!col || !item || !cellWritable(item, col)) return;
		if (fieldFor(col)?.type !== 'boolean') return;
		const current = (item as Record<string, unknown>)[col.key];
		void commitCell(r, c, current !== true, ++actionSeq);
	}

	/** ⌘Z — invert the newest action, one gesture per press: a cell commit,
	 *  a flip, or a whole pasted block. Cells the row no longer carries
	 *  (changed since) skip; the rest reverts through the queue, unrecorded.
	 *  The popped group moves to the redo stack — ⌘⇧Z re-applies it. */
	async function undo(): Promise<void> {
		const group = writeQueue.popUndoAction();
		if (!group) return;
		writeQueue.pushRedo(group);
		let skipped = false;
		for (const entry of group) {
			const r = items.findIndex((row) => rowKey(row) === entry.rowId);
			if (r < 0) {
				skipped = true;
				continue;
			}
			const row = items[r] as Record<string, unknown>;
			const revert: Record<string, unknown> = {};
			for (const [key, after] of Object.entries(entry.after)) {
				if (!valueEquals(row[key], after)) skipped = true;
				else revert[key] = entry.before[key];
			}
			if (Object.keys(revert).length > 0) void commitDiff(r, revert);
		}
		if (skipped) {
			toast({ message: m.grid_undo_skipped(), variant: 'error' });
		}
	}

	/** ⌘⇧Z — re-apply the newest undone action. Cells the row no longer
	 *  carries (changed since the undo) skip. The group returns to the undo
	 *  stack, so ⌘Z inverts it again. */
	async function redo(): Promise<void> {
		const group = writeQueue.popRedo();
		if (!group) return;
		writeQueue.restoreUndo(group);
		let skipped = false;
		for (const entry of group) {
			const r = items.findIndex((row) => rowKey(row) === entry.rowId);
			if (r < 0) {
				skipped = true;
				continue;
			}
			const row = items[r] as Record<string, unknown>;
			const apply: Record<string, unknown> = {};
			for (const [key, before] of Object.entries(entry.before)) {
				if (!valueEquals(row[key], before)) skipped = true;
				else apply[key] = entry.after[key];
			}
			if (Object.keys(apply).length > 0) void commitDiff(r, apply);
		}
		if (skipped) {
			toast({ message: m.grid_redo_skipped(), variant: 'error' });
		}
	}

	/** The editor's commit — close, write, then move as the key asked. A
	 *  keyboard commit refocuses a cell: the unmounting input drops focus
	 *  to the body, and the next chord (⌘Z, Esc) must still reach the grid. */
	function handleEditorCommit(value: unknown, move: CommitMove): void {
		const current = editing;
		closeEditor();
		if (!current) return;
		if (current.r === newRow) {
			// The ghost row's commit stages into the draft and drives the
			// create attempt — it owns the selection move.
			void commitNewRowCell(current.c, value, move);
			return;
		}
		void commitCell(current.r, current.c, value, ++actionSeq);
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

	// ── Paste (Excel → grid) ──────────────────────────────────────────

	/** The native paste on the focused cell — the container hears it bubble.
	 *  An open editor's input keeps its own paste untouched. */
	function handlePaste(e: ClipboardEvent): void {
		if (editing || isTypingTarget(e.target)) return;
		if (!selRange) return;
		const text = e.clipboardData?.getData('text/plain');
		if (!text) return;
		e.preventDefault();
		pasteBlock(text);
	}

	/** The cells the previous paste marked with a parse error. The next
	 *  paste clears them first, so the frames always reflect the latest
	 *  attempt instead of accumulating across retries. */
	let pasteMarked: { rowId: string; key: string }[] = [];

	/** The paste-mark fade timeline — a full-price hold, then a slow ease
	 *  out. Long enough to read, gone without user action. */
	const MARK_HOLD_MS = 5000;
	const MARK_FADE_MS = 3000;
	let markSeq = 0;

	/** The fade schedule for one paste mark: after the hold, flip the
	 *  `fading` phase (the CSS eases the frame out); after the fade, drop
	 *  the entry. Both steps re-check the token — a re-marked cell or a
	 *  real write on it owns the schedule from then on. */
	function scheduleMarkFade(rowId: string, key: string, mark: number): void {
		setTimeout(() => {
			const entry = pendingFor(rowId, key);
			if (entry?.status !== 'error' || entry.mark !== mark || entry.fading) return;
			setPending(rowId, key, { ...entry, fading: true });
			setTimeout(() => {
				const final = pendingFor(rowId, key);
				if (final?.status !== 'error' || final.mark !== mark) return;
				setPending(rowId, key, null);
			}, MARK_FADE_MS);
		}, MARK_HOLD_MS);
	}

	/**
	 * Land a pasted TSV block with its top-left at the selection's top-left.
	 * The block never leaves the loaded page: rows and columns past it are
	 * skipped, as are read-only cells (counted, one toast). A cell whose text
	 * does not coerce keeps its value and takes the error frame (counted).
	 * Each touched row sends one PATCH; ⌘Z then reverts a row per press.
	 */
	function pasteBlock(text: string): void {
		const block = parseTSV(text);
		const range = selRange;
		if (block.length === 0 || !range || items.length === 0) return;
		// The previous attempt's frames drop here — a repeated Ctrl+V re-marks
		// only what the new block still fails.
		for (const { rowId, key } of pasteMarked) {
			if (pendingFor(rowId, key)?.status === 'error') setPending(rowId, key, null);
		}
		pasteMarked = [];
		const tz = displayTimezone();
		let skipped = 0;
		let failed = 0;
		let landed = 0;
		const action = ++actionSeq;
		const rowWrites: { r: number; changes: Record<string, unknown> }[] = [];
		for (let i = 0; i < block.length; i++) {
			const r = range.rowStart + i;
			if (r > maxRow) {
				skipped += block.slice(i).reduce((n, row) => n + row.length, 0);
				break;
			}
			const item = items[r];
			if (!item) break;
			const record = item as Record<string, unknown>;
			const rowId = rowKey(item);
			const changes: Record<string, unknown> = {};
			for (let j = 0; j < block[i].length; j++) {
				const c = range.colStart + j;
				if (c > maxCol) {
					skipped += block[i].length - j;
					break;
				}
				const col = columns[c];
				if (!col || !cellWritable(item, col)) {
					skipped++;
					continue;
				}
				const field = fieldFor(col);
				if (!field) {
					skipped++;
					continue;
				}
				const result = coercePaste(field, block[i][j], {
					current: record[col.key],
					timezone: tz
				});
				if (!result.ok) {
					failed++;
					pasteMarked.push({ rowId, key: col.key });
					const mark = ++markSeq;
					setPending(rowId, col.key, {
						status: 'error',
						value: record[col.key],
						before: record[col.key],
						message: result.error,
						mark
					});
					scheduleMarkFade(rowId, col.key, mark);
					continue;
				}
				changes[col.key] = result.value;
				// A stale error frame from an earlier failed paste marks text that
				// never landed. This cell now coerces — drop the frame up front:
				// the write may turn out a no-op (the value already matches the
				// row) and never touch the pending state itself.
				if (pendingFor(rowId, col.key)?.status === 'error') {
					setPending(rowId, col.key, null);
				}
			}
			if (Object.keys(changes).length > 0) {
				rowWrites.push({ r, changes });
				landed += Object.keys(changes).length;
			}
		}
		for (const { r, changes } of rowWrites) void commitDiff(r, changes, action);
		if (landed > 0) {
			// The selection covers the pasted block (clamped into the page).
			selection.setFocus(range.rowStart, range.colStart, maxRow, maxCol);
			selection.extendTo(
				Math.min(range.rowStart + block.length - 1, maxRow),
				Math.min(range.colStart + block[0].length - 1, maxCol),
				maxRow,
				maxCol
			);
			refocusCell(range.rowStart, range.colStart);
		}
		if (skipped > 0) toast({ message: m.grid_paste_readonly({ count: skipped }) });
		if (failed > 0) {
			toast({ message: m.grid_paste_unreadable({ count: failed }), variant: 'error' });
		}
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
		// Undo / redo — the session history. ⌘Z walks back one action per
		// press (a multi-row paste reverts in one press); ⌘⇧Z and ⌘Y walk
		// forward.
		if ((e.metaKey || e.ctrlKey) && (key === 'z' || key === 'Z')) {
			e.preventDefault();
			if (e.shiftKey) void redo();
			else void undo();
			return;
		}
		if ((e.metaKey || e.ctrlKey) && (key === 'y' || key === 'Y')) {
			e.preventDefault();
			void redo();
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
				selection.move(1, 0, extend, navMaxRow, maxCol);
				focusAfterMove();
				break;
			case 'ArrowUp':
				e.preventDefault();
				selection.move(-1, 0, extend, navMaxRow, maxCol);
				focusAfterMove();
				break;
			case 'ArrowRight':
				e.preventDefault();
				selection.move(0, 1, extend, navMaxRow, maxCol);
				focusAfterMove();
				break;
			case 'ArrowLeft':
				e.preventDefault();
				selection.move(0, -1, extend, navMaxRow, maxCol);
				focusAfterMove();
				break;
			case 'Home':
				e.preventDefault();
				selection.setFocus(0, 0, navMaxRow, maxCol);
				focusAfterMove();
				break;
			case 'End':
				e.preventDefault();
				selection.setFocus(navMaxRow, 0, navMaxRow, maxCol);
				focusAfterMove();
				break;
			case 'Enter':
				// Editing takes Enter over on a writable cell; elsewhere it
				// keeps opening the row like the table's Enter does. The ghost
				// row's writable cells take the editor from the create grant.
				if (
					focus &&
					((focus.row === newRow &&
						focusCol &&
						newCellWritable(focusCol) &&
						fieldFor(focusCol)?.type !== 'boolean') ||
						(focusRowItem &&
							focusCol &&
							cellWritable(focusRowItem, focusCol) &&
							fieldFor(focusCol)?.type !== 'boolean'))
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
				// The pending new row clears first — Esc is the row-level
				// cancel: the draft and its error frames drop, the prompt
				// returns. With no draft, the failed cells revert and the
				// range clears (the existing contract).
				if (newDirty || newErrors.size > 0) {
					newDraft = {};
					newErrors = new Map();
				} else {
					revertErrorCells();
					selection.clear();
				}
				break;
			default:
				// A printable char starts the editor with that char — the
				// spreadsheet's type-to-replace. Booleans have no edit mode.
				// The ghost row takes the same path from the create grant.
				if (
					key.length === 1 &&
					focus &&
					focusCol &&
					fieldFor(focusCol)?.type !== 'boolean' &&
					(focus.row === newRow
						? newCellWritable(focusCol)
						: focusRowItem != null && cellWritable(focusRowItem, focusCol))
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
			style={`--grid-cols: ${gridTemplate}; --row-h: ${ROW_HEIGHT}px; --mark-fade-ms: ${MARK_FADE_MS}ms;`}
			role="grid"
			aria-rowcount={items.length + (canCreateRow ? 1 : 0)}
			aria-colcount={columns.length + (selectable ? 1 : 0)}
			tabindex="0"
			onkeydown={handleKeydown}
			onpaste={handlePaste}
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
						class:gutter-error={errorRows.has(rowKey(item))}
						style="left: 0"
						aria-hidden="true"
						title={rowErrorTitle(rowKey(item))}
						onmousedown={(e) => gutterMouseDown(r, e)}
					>
						{#if savingRows.has(rowKey(item))}
							<span class="gutter-spin"></span>
						{:else}
							{r + 1}
						{/if}
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
						{@const showTip =
							cellEntry?.status === 'error' && tipHover?.r === r && tipHover?.c === c}
						<div
							class="g-cell {colAlign(col)}"
							class:frozen={sticky != null}
							class:frozen-last={frozenLast}
							class:in-range={inRange && !isFocus}
							class:focused={isFocus}
							class:computed={isComputed(col)}
							class:saving={cellEntry?.status === 'saving'}
							class:cell-error={cellEntry?.status === 'error'}
							class:cell-fading={cellEntry?.fading === true}
							class:cell-tip-open={showTip}
							class:stale={isComputed(col) && savingRows.has(rowKey(item))}
							class:editing={isEditing}
							style={sticky != null ? `left: ${sticky}px` : ''}
							role="gridcell"
							tabindex="-1"
							aria-selected={inRange}
							aria-colindex={c + 1}
							data-row={r}
							data-col={c}
							onmousedown={(e) => cellMouseDown(r, c, e)}
							onmouseenter={(e) => cellMouseEnter(r, c, e)}
							onmouseleave={() => cellMouseLeave(r, c)}
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
							{#if showTip && cellEntry}
								<span class="error-tip" use:placeFloater>{cellEntry.message}</span>
							{/if}
						</div>
					{/each}
				</div>
			{:else}
				{#if !loading && !error}
					<div class="g-empty">{m.table_records_empty()}</div>
				{/if}
			{/each}

			<!-- ghost new-row line (`allow_create`) -->
			{#if canCreateRow}
				{@const newRowLabel = doctype?.label ?? doctype?.doctype ?? ''}
				<div
					class="g-row g-new"
					class:g-new-creating={creating}
					class:g-new-pending={newDirty || newErrors.size > 0}
					role="row"
					aria-rowindex={items.length + 1}
				>
					<div
						class="g-cell gutter new-gutter frozen"
						class:frozen-last={lastSticky === 'gutter'}
						class:gutter-error={newErrors.size > 0}
						style="left: 0"
						aria-hidden="true"
						title={newErrors.values().next().value}
					>
						{#if creating}
							<span class="gutter-spin"></span>
						{:else}
							+
						{/if}
					</div>
					{#if selectable}
						<div
							class="g-cell check frozen"
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
						{@const inRange =
							selRange != null &&
							selRange.rowStart <= newRow &&
							newRow <= selRange.rowEnd &&
							selRange.colStart <= c &&
							c <= selRange.colEnd}
						{@const isFocus =
							inRange &&
							selRange!.rowStart === newRow &&
							selRange!.rowEnd === newRow &&
							selRange!.colStart === c &&
							selRange!.colEnd === c}
						{@const errText = newErrors.get(col.key)}
						{@const value = newCellValue(col.key)}
						{@const hasValue = value !== undefined && value !== null && value !== ''}
						{@const isEditing = editing?.r === newRow && editing?.c === c}
						{@const showTip = errText != null && tipHover?.r === newRow && tipHover?.c === c}
						<div
							class="g-cell new-cell {colAlign(col)}"
							class:frozen={sticky != null}
							class:frozen-last={frozenLast}
							class:in-range={inRange && !isFocus}
							class:focused={isFocus}
							class:cell-error={errText != null}
							class:cell-tip-open={showTip}
							class:editing={isEditing}
							style={sticky != null ? `left: ${sticky}px` : ''}
							role="gridcell"
							tabindex="-1"
							aria-selected={inRange}
							aria-colindex={c + 1}
							data-row={newRow}
							data-col={c}
							onmousedown={(e) => cellMouseDown(newRow, c, e)}
							onmouseenter={(e) => cellMouseEnter(newRow, c, e)}
							onmouseleave={() => cellMouseLeave(newRow, c)}
							ondblclick={() => openEditor(null)}
						>
							{#if isEditing}
								<CellEditor
									field={fieldFor(col)!}
									label={col.label}
									{value}
									seed={editing!.seed}
									{driver}
									oncommit={handleEditorCommit}
									oncancel={handleEditorCancel}
									bind:this={editorApi}
								/>
							{:else if hasValue}
								<FieldValue
									{value}
									fieldType={fieldFor(col)?.type ?? null}
									fieldDef={fieldFor(col)}
								/>
							{:else if newMissingKeys.has(col.key) && newDirty}
								<!-- The invalid state's inline cue: the row stages values
								     but cannot create until the required field is named
								     (the design's "created once named"). -->
								<span class="new-hint new-hint-missing">
									{m.grid_new_row_missing({ field: col.label ?? col.key })}
								</span>
							{:else if c === newPromptCol && !newDirty}
								<span class="new-hint">
									{m.grid_new_row_prompt({ doctype: newRowLabel })}
								</span>
							{/if}
							{#if showTip && errText}
								<span class="error-tip" use:placeFloater>{errText}</span>
							{/if}
						</div>
					{/each}
				</div>
			{/if}

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
	/* Fill chain: the list-view host gives the grid its height on the grid
	   surface. The toolbar and the footer keep their content height. The row
	   frame takes the rest, and its rows scroll inside. Outside a flex column
	   parent (stories), flex does nothing and the grid keeps content height. */
	.grid-wrap {
		display: flex;
		flex-direction: column;
		gap: 0;
		min-width: 0;
		min-height: 0;
		flex: 1;
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

	.g-row:not(.g-head):not(.g-foot):not(.g-new-pending) .g-cell:hover {
		background: var(--surface-2);
	}

	/* The failed row's gutter keeps its danger tint under the pointer — the
	   failure signal outranks the hover feedback there. */
	.g-row:not(.g-head):not(.g-foot) .g-cell.gutter.gutter-error:hover {
		background: var(--danger-weak);
	}

	/* The pending ghost line keeps its tint under the pointer — the "not
	   saved" signal outranks the hover feedback there. */

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

	/* ── Gutter commit status ── */

	/* The gutter is the row's commit-status column: the number yields to a
	   spinner while a write flies, and reads danger when the write failed
	   (the failing cells carry the frames and the tooltip). The spinner
	   copies the DeployPanel's — slowed, not stopped, under reduced motion. */
	.gutter-spin {
		width: 12px;
		height: 12px;
		border: 2px solid var(--border-strong);
		border-top-color: var(--accent-ink);
		border-radius: 50%;
		animation: gutter-spin 0.7s linear infinite;
	}

	@keyframes gutter-spin {
		to {
			transform: rotate(360deg);
		}
	}

	.g-cell.gutter.gutter-error {
		background: var(--danger-weak);
		color: var(--danger);
	}

	@media (prefers-reduced-motion: reduce) {
		.gutter-spin {
			animation-duration: 1.4s;
		}
	}

	/* A rejected cell keeps the typed value under an error frame; the
		floating failure label carries the 422's message. */
	.g-cell.cell-error {
		box-shadow: inset 0 0 0 2px var(--danger);
	}

	/* The failing cell's reason — a floating label under the cell. It shows
	   only while the pointer sits on the failing cell, and hides the moment
	   the pointer leaves (the frame stays). Text renders through the
	   validation catalogue when the 422 names the field. The placeFloater
	   action flips it above the cell when the grid's box would cut it. */
	.error-tip {
		position: absolute;
		top: calc(100% + 6px);
		left: 0;
		z-index: 6;
		max-width: 280px;
		padding: 6px 10px;
		border: 1px solid var(--danger);
		border-radius: var(--r-sm);
		background: var(--surface);
		box-shadow: var(--sh-1);
		color: var(--danger);
		font-size: 12px;
		line-height: 1.45;
		white-space: normal;
		text-align: left;
		pointer-events: none;
	}

	/* The label escapes the cell's own clipping — only while it shows, so a
	   long rejected value never paints over its neighbours in the idle
	   state. */
	.g-cell.cell-tip-open {
		overflow: visible;
	}

	/* The flip classes come from the placeFloater action at runtime — they
	   never appear in this template, so the selectors target them through
	   `:global` (a plain class selector would be pruned as unused). */
	.error-tip:global(.open-up) {
		top: auto;
		bottom: calc(100% + 6px);
	}

	.error-tip:global(.open-right) {
		left: auto;
		right: 0;
	}

	/* A paste mark's fade phase — the frame eases out over the fade window
		(after the hold) and the entry drops when it ends. The frame still
		appears instantly: the transition lives on the fading state only.
		base.css already stills every transition under reduced motion. */
	.g-cell.cell-error.cell-fading {
		box-shadow: inset 0 0 0 2px transparent;
		transition: box-shadow var(--mark-fade-ms, 3000ms) ease;
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

	/* ── Ghost new-row line ── */

	/* The `+` gutter carries the create affordance colour. */
	.new-gutter {
		color: var(--accent-ink);
		font-size: 15px;
	}

	/* Ghost values read one step dimmer than real data — they are what the
	   create will send, not what the collection holds. */
	.new-cell {
		color: var(--text-2);
	}

	.new-hint {
		font-style: italic;
		color: var(--text-3);
		font-size: 13px;
		overflow: hidden;
		text-overflow: ellipsis;
	}

	/* The missing-required hint sits on the blocking cell — danger ink. */
	.new-hint-missing {
		color: var(--danger);
	}

	/* A create in flight dims the whole line — the values are not settled. */
	.g-new-creating .g-cell {
		opacity: 0.55;
	}

	/* The unsaved line reads red: the draft is staged but the row does not
	   exist yet (the required gate, a create in flight, or a refused 422
	   holds it). The faint danger tint sits on every cell, and it drops
	   when the create lands or Esc clears the draft. This rule sits after
	   `.in-range` above, so the red wins the specificity tie when the
	   pending line sits inside a selection range. */
	.g-new-pending .g-cell {
		background: var(--danger-weak);
	}

	.g-new-pending .new-gutter {
		color: var(--danger);
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
