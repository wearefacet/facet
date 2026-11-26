// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { DataSource } from '$lib/datasource/interface.js';
import type { DataDriver } from '$lib/datasource/driver.js';
import type { DoctypeDef } from '$lib/doctype/types.js';
import type { ReferenceClickHandler } from '$lib/template-types.js';
import type { GridColumnSummary } from '$lib/collectionView/types.js';
import type { SortState, ToolbarActionsArgs } from '$lib/table/types.js';
import type { Snippet } from 'svelte';

/**
 * A resolved grid column — the view config's column with its display
 * metadata resolved by the host (label through `resolveColumnLabel`,
 * sortable through the doctype's sortable set). Widths feed the sticky
 * frozen math, so a non-px width falls back to the default.
 */
export interface GridColumn {
	/** Content field key this column reads from. */
	key: string;
	/** Header label text. */
	label: string;
	/** Inline width (e.g. `"300px"`). A missing or non-px width renders at
	 *  the default width and never freezes. */
	width?: string;
	/** Horizontal alignment. Defaults to `"left"`. */
	align?: 'left' | 'right' | 'center';
	/**
	 * Writable column. The grid treats a writable column as editable unless
	 * `false` (the editing affordances land with the editors phase); the
	 * field-level gates (`read_only`/`write_only`/`data` types) still win.
	 */
	editable?: boolean;
	/** Σ-row aggregate for this column. Absent = an empty Σ cell. */
	summary?: GridColumnSummary;
	/** Whether the header sorts on click (the host owns the sort state). */
	sortable?: boolean;
}

/** Props accepted by the Grid component. */
export interface GridProps<T> {
	/** Resolved column definitions. */
	columns: GridColumn[];
	/** DataSource used to load rows, aggregates, and counts. */
	datasource: DataSource<T>;
	/** Doctype definition enabling the schema-aware toolbar and typed cells. */
	doctype?: DoctypeDef;
	/** Driver used to resolve `reference` filter comboboxes in the toolbar. */
	driver?: DataDriver;
	/** Active filter map (`field__op` → value) — the toolbar's chips. */
	filters?: Record<string, unknown>;
	/** Called whenever the toolbar changes the active filters. */
	onFilterChange?: (filters: Record<string, unknown>) => void;
	/** Current sort state — the first entry of the view's `grid.sort`. */
	sort?: SortState | null;
	/** Called with the column key when a sortable header is clicked. */
	onSort?: (key: string) => void;
	/** Leading data columns pinned left, after the gutter and checkbox. */
	frozen?: number;
	/** Whether the first column is a checkbox for row selection. */
	selectable?: boolean;
	/** Set of currently checkbox-selected row keys. */
	selected?: Set<string>;
	/** Called with the row key when a checkbox is toggled. */
	onSelect?: (key: string) => void;
	/** Called when the header checkbox is toggled. */
	onSelectAll?: () => void;
	/** Function that returns a stable unique key for a row item. */
	rowKey: (item: T) => string;
	/** Number of items per page. Defaults to 25. */
	pageSize?: number;
	/** Open the row's peek drawer — row click, Enter, or Space. */
	onRowClick?: (item: T) => void;
	/** The ghost new-row line under the rows (`config.grid.allow_create`).
	 *  The component ANDs it with the viewer's `create` grant; a denied
	 *  create (403) locks the line off for the session. */
	allowCreate?: boolean;
	/** Click handler forwarded to reference capsules (peek navigation). */
	onReferenceClick?: ReferenceClickHandler;
	/** Snippet receiving the toolbar state (the view-export controls). */
	toolbarActions?: Snippet<[ToolbarActionsArgs<T>]>;
}
