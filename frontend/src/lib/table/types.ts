// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { Snippet } from 'svelte';
import type { DataSource } from '$lib/datasource/interface.js';
import type { DataDriver } from '$lib/datasource/driver.js';
import type { DoctypeDef } from '$lib/doctype/types.js';
import type { ReferenceClickHandler } from '$lib/template-types.js';

/** Horizontal alignment for a column's header and body cells. */
export type Align = 'left' | 'right' | 'center';

/** Defines a single column in the table. */
export interface Column<T> {
	/** Unique key used to read the default cell value from a row item. */
	key: string;
	/** Header label text. */
	label: string;
	/** Horizontal alignment. Defaults to `"left"`. */
	align?: Align;
	/** Whether the column header shows a sort arrow and responds to clicks. */
	sortable?: boolean;
	/** Inline width (e.g. `"120px"`, `"2fr"`). */
	width?: string;
	/**
	 * Optional snippet for custom cell rendering.
	 * When omitted, the cell displays `item[key]` cast to string.
	 */
	render?: Snippet<[item: T, column: Column<T>]>;
	/**
	 * Inline-editable cell. When `true`, the column resolves to a `boolean`
	 * field of the table's `doctype`, the field is not `read_only`/
	 * `write_only`, and the viewer holds `update` on the doctype, the cell
	 * renders as a toggle that applies the update directly. Other field
	 * types ignore the flag and render read-only.
	 */
	editable?: boolean;
}

/**
 * A column whose `align` or `sortable` has been merged with defaults.
 * @internal
 */
export interface ResolvedColumn<T> extends Column<T> {
	align: Align;
}

/** Describes the current sort direction for a column. */
export interface SortState {
	key: string;
	desc: boolean;
}

/** The table state the `toolbarActions` snippet receives — the columns the
 * table shows, the compacted filter map the datasource receives (freshly
 * seeded empty chips dropped, exactly what the last list call carried), and
 * the current sort. The doctype page forwards it to the view export. */
export interface ToolbarActionsArgs<T> {
	columns: Column<T>[];
	filters: Record<string, unknown>;
	sort: SortState | null;
}

/** Props accepted by the Table component. */
export interface TableProps<T> {
	/** Column definitions. */
	columns: Column<T>[];
	/** DataSource used to load rows with pagination, sorting, and filtering. */
	datasource: DataSource<T>;
	/** Current sort state. */
	sort?: SortState | null;
	/** Called with the column key when a sortable header is clicked. */
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
	/** Number of items per page. Defaults to 25. */
	pageSize?: number;
	/** Doctype definition enabling the schema-aware toolbar. */
	doctype?: DoctypeDef;
	/** Driver used to resolve `reference` filter comboboxes. */
	driver?: DataDriver;
	/** Active filter map (`field__op` → value). */
	filters?: Record<string, unknown>;
	/** Called whenever the toolbar changes the active filters. */
	onFilterChange?: (filters: Record<string, unknown>) => void;
	/**
	 * Click handler forwarded to reference capsules rendered by the
	 * schema-aware default cell renderer. When unset, reference capsules
	 * inside the table are display-only (not clickable).
	 */
	onReferenceClick?: ReferenceClickHandler;
	/**
	 * localStorage key that keeps this listing's manual state (sort,
	 * filters, rows-per-page) across visits. When set, the table restores
	 * the state at mount and on a key change, and writes it back on every
	 * header or toolbar edit. `null` (default) keeps the state purely
	 * in-memory. Minted per collection view by `ListView` through
	 * `viewStateStorageKey`.
	 */
	persistKey?: string | null;
}
