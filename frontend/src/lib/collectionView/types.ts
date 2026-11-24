// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Types for CollectionView — a saved listing surface configuration
 * (`core.CollectionView` doctype, a child of `core.DocType`).
 *
 * A view is either general (shared, `owner_id` absent) or personal
 * (`owner_id` set to the creator's account id). Supported surfaces are
 * `table`, `calendar`, and `kanban`; `grid` will follow.
 */

import type { FieldType } from '$lib/doctype/types.js';

/** Supported presentation layouts for a doctype listing. */
export type CollectionSurface = 'table' | 'calendar' | 'kanban';

/** A single column declaration in a table-surface view config. */
export interface CollectionViewColumn {
	/** Content field key this column reads from (e.g. "name", "amount"). */
	key: string;
	/** Optional header label override. Falls back to `key`. */
	label?: string;
	/** Optional inline width (e.g. "120px", "2fr"). */
	width?: string;
	/**
	 * Inline-editable cell. Present (as `true`) only on boolean columns the
	 * author marked updatable — the table renders those cells as toggles
	 * gated on the viewer's `update` permission. Absent means read-only.
	 */
	editable?: true;
}

/** Surface-specific configuration. Currently `table`, `calendar`, and `kanban`. */
export interface CollectionViewConfig {
	/** Ordered column definitions for the `table` surface. */
	columns?: CollectionViewColumn[];
	/** Calendar-surface configuration. Present when `surface === 'calendar'`. */
	calendar?: CalendarViewConfig;
	/** Kanban-surface configuration. Present when `surface === 'kanban'`. */
	kanban?: KanbanViewConfig;
}

/**
 * Discriminator kind for a calendar view — derived from the discriminator
 * field's backend `FieldType` plus whether `end_field` is set.
 *
 * | Backend type(s)         | `end_field` set? | Kind              |
 * | ---------------------- | ---------------- | ----------------- |
 * | `date`                 | no               | `date`            |
 * | `date` + `date`        | yes              | `date-range`      |
 * | `dateperiod`           | n/a              | `date-range`      |
 * | `datetime`             | no               | `datetime`        |
 * | `datetime` + `datetime`| yes              | `datetime-range`  |
 * | `period`               | n/a              | `datetime-range`  |
 */
export type CalendarDiscriminatorKind = 'date' | 'date-range' | 'datetime' | 'datetime-range';

/**
 * Calendar-surface configuration.
 *
 * The discriminator is a single backend field (or a `(date|datetime)` field
 * paired with `end_field`) that anchors each document on the calendar grid.
 * Field eligibility comes from the doctype schema — see
 * {@link calendarDiscriminatorKind} for the mapping rules.
 */
export interface CalendarViewConfig {
	/** Field key whose value anchors the document on the calendar. */
	discriminator: string;
	/**
	 * Optional second field forming a range with `discriminator`. Only
	 * meaningful when `discriminator` is `date` or `datetime` (a second
	 * `date`/`datetime` field). Ignored when `discriminator` is `period`
	 * or `dateperiod` (those model a range natively as `{start, end}`).
	 */
	end_field?: string | null;
	/** Field key whose value drives chip colour. `enum` or `reference`. */
	color_by?: string | null;
	/**
	 * Title template (e.g. `{name} {subject}`). Falls back to the
	 * doctype's first `string`/`longtext` field. `{$field}` placeholders
	 * resolve against the document's content.
	 */
	title_template?: string | null;
	/** Starting day of the week for grid layout. */
	week_start: 'monday' | 'sunday';
	/**
	 * Active filters applied to the fetched documents, keyed by `field__op`
	 * (e.g. `status__eq`). Persisted with the view so only matching documents
	 * are shown on the calendar.
	 */
	filters?: Record<string, unknown>;
}

/** Backend field types that can serve as a calendar discriminator. */
export const CALENDAR_DISCRIMINATOR_TYPES: ReadonlySet<FieldType> = new Set([
	'date',
	'datetime',
	'period',
	'dateperiod'
]);

/**
 * A resolved lane — the single runtime model for both kanban authoring
 * modes. A lane is a thin wrapper over one `list()` call: the filter
 * narrows the board partition, the view-level sort orders the cards, and
 * the page cap bounds the fetch.
 */
export interface KanbanLane {
	/** Header label shown above the card stack. */
	label: string;
	/** Accent colour for the lane dot. Hex string. Falls back per value/label. */
	color?: string;
	/** The lane's filter expression: `field__op` → value (e.g. `status__eq`). */
	filter: Record<string, unknown>;
}

/**
 * Kanban-surface configuration.
 *
 * Two authoring modes produce the same runtime shape:
 * - `values` derives one lane per value of the `group_by` enum field at
 *   render time; the lane filter is `{ "<group_by>__eq": value }`.
 * - `custom` stores the explicit lane list; render order is array order.
 *   Custom lanes may overlap or leave gaps — a document can appear in more
 *   than one lane.
 */
export interface KanbanViewConfig {
	/** Lane derivation mode. */
	mode: 'values' | 'custom';
	/** Values mode: the enum field key whose values become lanes. */
	group_by?: string;
	/** Custom mode: explicit lane list. Render order = array order. */
	lanes?: KanbanLane[];
	/**
	 * Values mode: display order of the lanes, as the group-by field's value
	 * keys (the enum value keys; `'true'` / `'false'` for a boolean). Keys
	 * missing from the list keep declaration order, appended after the listed
	 * ones; keys that no longer resolve are ignored. Absent = declaration
	 * order.
	 */
	lane_order?: string[];
	/**
	 * Values mode: lane keys hidden from the board. A hidden lane neither
	 * renders nor fetches — its documents show nowhere on the board.
	 */
	hidden_lanes?: string[];
	/**
	 * Drag & drop between lanes, writing the lane's value through a document
	 * update. Absent or false keeps the board read-only (the default, so
	 * views saved before the option existed stay read-only). A move also
	 * needs the viewer's `update` permission on the doctype and a lane whose
	 * filter is one writable `field__eq` entry.
	 */
	allow_move?: boolean;
	/**
	 * View-level base filter, merged into every lane query (e.g.
	 * `status__ne` narrows the whole board). On an exact filter-key
	 * collision the lane filter wins.
	 */
	filters?: Record<string, unknown>;
	/**
	 * Card sort within every lane — field keys, `-` prefix = descending,
	 * the `ListParams.sort` format passed through as-is. The surface
	 * defaults to `['-updated_at']` when absent.
	 */
	sort?: string[];
	/** Per-lane fetch cap. The surface defaults to 25 when absent. */
	page_size?: number;
}

/**
 * A saved listing view row, as returned by the
 * `core.DocType/:id/collection_view` endpoint.
 */
export interface CollectionView {
	/** Tab label shown in the listing UI. */
	name: string;
	/** Presentation layout. `table` or `calendar`. */
	surface: CollectionSurface;
	/** Surface-specific configuration. */
	config?: CollectionViewConfig;
	/**
	 * Creator account id for personal views; absent/null for general views.
	 * Forced server-side by the Lua create hook based on the matched scope.
	 */
	owner_id?: string;
}
