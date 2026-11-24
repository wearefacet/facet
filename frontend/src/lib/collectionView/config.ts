// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Pure config logic for the CollectionView editor (`CollectionViewEditor.svelte`).
 *
 * Everything here is a plain function over the doctype schema and the
 * editor's draft state — no Svelte reactivity, no data access. The
 * component owns the draft `$state` and calls these helpers to derive
 * pick lists, build the persisted config, and validate before save.
 */

import * as m from '$lib/paraglide/messages';
import { SYSTEM_TIMESTAMP_FIELD_DEFS, hasOperator } from '$lib/doctype/filters.js';
import { humanizeLabel } from '$lib/calendar/discriminator.js';
import { validateLanes, groupByLaneKeys } from '$lib/kanban/lanes.js';
import { isSortableField } from '$lib/doctype/types.js';
import { CALENDAR_DISCRIMINATOR_TYPES } from './types.js';
import type {
	CollectionView,
	CollectionViewColumn,
	CollectionViewConfig,
	CollectionSurface,
	KanbanLane,
	KanbanViewConfig
} from './types.js';
import type { FieldDef } from '$lib/doctype/types.js';

/** Field types that never become table columns (containers, secrets).
 *  `data` (computed) fields ARE pickable — the column editor offers them —
 *  but they never seed a default column set. */
const SKIP_TYPES: ReadonlySet<FieldDef['type']> = new Set([
	'object',
	'array',
	'child',
	'data',
	'secret'
]);

/** Field types the column picker never offers (containers and secrets).
 *  Wider than {@link SKIP_TYPES}: a computed (`data`) field is a legitimate
 *  manual column (the assistant can author one), only the seed omits it. */
const PICKER_SKIP_TYPES: ReadonlySet<FieldDef['type']> = new Set([
	'object',
	'array',
	'child',
	'secret'
]);

/** Flat `{ value, label }` entry for a `Select` picker. */
export interface FieldOption {
	value: string;
	label: string;
}

/**
 * The editor's authored state, handed to {@link buildConfig},
 * {@link buildPayload}, and {@link validateDraft}.
 */
export interface CollectionViewDraft {
	name: string;
	surface: CollectionSurface;
	columns: CollectionViewColumn[];
	discriminator: string;
	endField: string;
	colorBy: string;
	titleTemplate: string;
	weekStart: 'monday' | 'sunday';
	filters: Record<string, unknown>;
	/** Fields the FilterBar may filter on — stale filter keys drop against it. */
	filterableFields: FieldDef[];
	/** The doctype's schema fields — the candidate pool the capability
	 *  gates (group-by, discriminator, end field) resolve against. */
	fields: FieldDef[];
	/** Kanban lane derivation mode. */
	kanbanMode: 'values' | 'custom';
	/** Kanban values mode: the enum field key whose values become lanes. */
	groupBy: string;
	/** Kanban values mode: the authored lane order — the value keys, display
	 *  order. Complete against the group-by field's declared values; the
	 *  editor normalizes it when the field changes. */
	laneOrder: string[];
	/** Kanban values mode: the hidden lane keys (the values not shown). */
	hiddenLanes: string[];
	/** Kanban custom mode: ordered lane list. */
	lanes: KanbanLane[];
	/** Kanban card sort field; empty means the surface default. */
	sortField: string;
	/** Kanban card sort direction (descending when true — the `-` prefix). */
	sortDesc: boolean;
	/** Kanban: drag & drop moves between lanes enabled. */
	allowMove: boolean;
	/** Defs the sort picker offers — the sortable subset of the pickable
	 *  fields. `buildConfig` drops a `sortField` that no longer resolves
	 *  here (removed field, or a type the backend refuses to sort). */
	sortFields: FieldDef[];
}

/**
 * Selectable flat fields plus the system-managed timestamp columns
 * (`created_at` / `updated_at`). Every document carries the timestamps in
 * its `meta` — the Table's loader flattens them onto the row — so they are
 * selectable for any doctype. The `title` is the picker label and the
 * default column header.
 *
 * Computed (`data`) fields are pickable: the picker is the manual door to
 * the same configs the assistant authors directly. Containers and secrets
 * stay excluded.
 */
export function pickableFields(fields: FieldDef[]): FieldDef[] {
	return [...fields.filter((f) => !PICKER_SKIP_TYPES.has(f.type)), ...SYSTEM_TIMESTAMP_FIELD_DEFS];
}

/**
 * Fields a kanban card sort may target: the pickable list narrowed to the
 * types the backend sorts on (through `isSortableField` — the mirror of
 * `Document::List#sort_expression_for` in `src/document/list.cr`). The
 * backend answers `422 unsortable_field` for anything outside the set, so
 * the sort picker must never offer one.
 */
export function sortableFields(fields: FieldDef[]): FieldDef[] {
	return pickableFields(fields).filter((f) => isSortableField(f));
}

/**
 * Seed columns: the doctype's first 4 flat fields, so the user starts from
 * a sensible default rather than an empty list. System timestamps never
 * seed — they are offered on top of the schema, not part of it.
 *
 * Plain boolean fields seed with `editable: true`, mirroring the backend
 * seed rule (`CollectionView::Defaults`): state flags toggle directly in
 * the table. `read_only` / `write_only` booleans stay read-only.
 */
export function defaultColumns(fields: FieldDef[]): CollectionViewColumn[] {
	return fields
		.filter((f) => !SKIP_TYPES.has(f.type))
		.slice(0, 4)
		.map((f) => {
			const col: CollectionViewColumn = { key: f.key, label: f.title ?? f.key };
			if (f.type === 'boolean' && !f.read_only && !f.write_only) col.editable = true;
			return col;
		});
}

/** Pickable entries not yet added as columns. */
export function remainingFields(fields: FieldDef[], columns: CollectionViewColumn[]): FieldDef[] {
	const used = new Set(columns.map((c) => c.key));
	return fields.filter((f) => !used.has(f.key));
}

/**
 * Flat schema fields plus the system timestamp defs, deduped by key. Every
 * document carries `created_at` / `updated_at` in its `meta`, so they anchor
 * a calendar (and pair as range ends) for any doctype. The backend reserves
 * both keys (`Doctype::Validation`), so a schema field can never shadow them
 * — the guard keeps hand-built field lists honest anyway.
 */
function withSystemTimestamps(fields: FieldDef[]): FieldDef[] {
	const keys = new Set(fields.map((f) => f.key));
	return [...fields, ...SYSTEM_TIMESTAMP_FIELD_DEFS.filter((f) => !keys.has(f.key))];
}

/**
 * Fields eligible as a calendar discriminator: the schema's
 * date/datetime/period/dateperiod fields plus the system timestamps, each
 * able to serve the filter the surface emits for it. A single-value
 * discriminator window-filters `__gte`/`__lte` on the field itself, so a
 * date/datetime needs both operators (the backend's `comparison`
 * capability). The range types fetch their window with no field filter at
 * all — native range, narrowed client-side (see
 * `buildCalendarWindowFilter`) — so they carry no operator requirement.
 * The result can be empty: a doctype whose only date fields lack the
 * comparison capability has no saveable calendar discriminator.
 */
export function discriminatorFields(fields: FieldDef[]): FieldDef[] {
	return withSystemTimestamps(fields).filter(
		(f) => CALENDAR_DISCRIMINATOR_TYPES.has(f.type) && servesCalendarWindow(f)
	);
}

/** True when the field serves the window filter the calendar emits for its type. */
function servesCalendarWindow(f: FieldDef): boolean {
	if (f.type === 'period' || f.type === 'dateperiod') return true;
	return hasOperator(f, 'gte') && hasOperator(f, 'lte');
}

/** Second date/datetime field forming a range with the discriminator. The
 *  window filter bounds the range with `end_field__gte`, so a sibling
 *  without the `gte` operator never qualifies. */
export function endFields(fields: FieldDef[], discriminator: string): FieldDef[] {
	const all = withSystemTimestamps(fields);
	const t = all.find((f) => f.key === discriminator)?.type;
	if (t === 'date')
		return all.filter((f) => f.type === 'date' && f.key !== discriminator && hasOperator(f, 'gte'));
	if (t === 'datetime')
		return all.filter(
			(f) => f.type === 'datetime' && f.key !== discriminator && hasOperator(f, 'gte')
		);
	return [];
}

/** enum/reference fields usable for chip colour. */
export function colorByFields(fields: FieldDef[], discriminator: string): FieldDef[] {
	return fields.filter(
		(f) => (f.type === 'enum' || f.type === 'reference') && f.key !== discriminator
	);
}

/**
 * Writable enum or boolean fields usable as a kanban group-by — one lane
 * per declared enum value, or the True/False pair for a boolean. Each lane
 * filters `field__eq`, so the field must serve the `eq` operator (the
 * backend's `equality` capability); a capability-less field would answer
 * every lane fetch with `422 unsupported_filter_operator`.
 */
export function groupableFields(fields: FieldDef[]): FieldDef[] {
	return fields.filter(
		(f) =>
			(f.type === 'enum' || f.type === 'boolean') &&
			!f.read_only &&
			!f.write_only &&
			hasOperator(f, 'eq')
	);
}

/** Flat `{ value, label }` options for the calendar `Select` pickers. */
export function fieldOptions(fields: FieldDef[]): FieldOption[] {
	return fields.map((f) => ({ value: f.key, label: f.title ?? humanizeLabel(f.key) }));
}

/** Reset a filter entry that no longer maps to a doctype field/operator. */
export function dropUnknownFilter(
	filters: Record<string, unknown>,
	fields: FieldDef[]
): Record<string, unknown> {
	const out: Record<string, unknown> = {};
	for (const [k, v] of Object.entries(filters)) {
		const idx = k.lastIndexOf('__');
		const name = idx >= 0 ? k.slice(0, idx) : k;
		const field = fields.find((f) => f.key === name);
		if (field && (field.operators?.length ?? 0) > 0) out[k] = v;
	}
	return out;
}

/** Surface-specific config for the current draft. */
export function buildConfig(draft: CollectionViewDraft): CollectionViewConfig {
	if (draft.surface === 'table') {
		return { columns: draft.columns.map((c) => ({ ...c })) };
	}
	if (draft.surface === 'kanban') {
		const kanban: KanbanViewConfig = { mode: draft.kanbanMode, page_size: 25 };
		if (draft.kanbanMode === 'values') {
			kanban.group_by = draft.groupBy.trim();
			// Lane order and visibility persist only against the field's current
			// declared values; stale keys (an enum value removed since) drop so
			// the stored config never carries keys the board cannot resolve.
			const field = draft.fields.find((f) => f.key === kanban.group_by);
			const declared = field ? groupByLaneKeys(field) : [];
			if (declared.length > 0) {
				const declaredSet = new Set(declared);
				const authoredSet = new Set(draft.laneOrder);
				const order = [
					...draft.laneOrder.filter((k) => declaredSet.has(k)),
					// Keys the draft order misses keep declaration order — append
					// them so the stored order is always complete.
					...declared.filter((k) => !authoredSet.has(k))
				];
				const sameOrder =
					order.length === declared.length && order.every((k, i) => k === declared[i]);
				if (!sameOrder) kanban.lane_order = order;
				const hidden = draft.hiddenLanes.filter((k) => declaredSet.has(k));
				if (hidden.length > 0) kanban.hidden_lanes = hidden;
			}
		} else {
			kanban.lanes = draft.lanes.map((lane) => {
				const copy: KanbanLane = { label: lane.label, filter: { ...lane.filter } };
				if (lane.color) copy.color = lane.color;
				return copy;
			});
		}
		// Persisted only when on — views saved before the option existed keep
		// their read-only boards.
		if (draft.allowMove) kanban.allow_move = true;
		kanban.filters = dropUnknownFilter(draft.filters, draft.filterableFields);
		const sortField = draft.sortField.trim();
		// One sort entry — the `-` prefix composes the descending direction.
		// Omitted when unset, or when the field no longer resolves to a
		// sortable def (removed from the schema, or a type the backend
		// refuses): the surface then applies its own default instead of
		// sending a sort that answers `422 unsortable_field`.
		const sortDef = draft.sortFields.find((f) => f.key === sortField);
		if (sortDef && isSortableField(sortDef)) {
			kanban.sort = [`${draft.sortDesc ? '-' : ''}${sortField}`];
		}
		return { kanban };
	}
	return {
		calendar: {
			discriminator: draft.discriminator.trim(),
			end_field: draft.endField || null,
			color_by: draft.colorBy || null,
			title_template: draft.titleTemplate || null,
			week_start: draft.weekStart,
			filters: dropUnknownFilter(draft.filters, draft.filterableFields)
		}
	};
}

/**
 * API payload for create. General views omit `owner_id` entirely (server
 * leaves it null). Personal views set `owner_id` so an unrestricted creator
 * still produces a personal view (the Lua hook only force-binds `owner_id`
 * when `ctx.actor.scope == "mine"`; unrestricted creators must opt in).
 */
export function buildPayload(
	draft: CollectionViewDraft,
	{ personal, viewerId }: { personal: boolean; viewerId?: string }
): CollectionView {
	const payload: CollectionView = {
		name: draft.name.trim(),
		surface: draft.surface,
		config: buildConfig(draft)
	};
	if (personal && viewerId) {
		payload.owner_id = viewerId;
	}
	return payload;
}

/** Validation outcome for a draft. */
export interface DraftValidation {
	nameError: string | null;
	columnsError: string | null;
	discriminatorError: string | null;
	/** Calendar: the optional end field cannot bound the range (no `gte`). */
	endFieldError: string | null;
	/** Kanban values mode: the group-by field is required. */
	groupByError: string | null;
	/** Kanban custom mode: at least one lane is required. Values mode: at
	 *  least one lane must stay visible. */
	lanesError: string | null;
	/** Kanban custom mode: per-lane errors, by lane index. */
	laneErrors: { index: number; error: string }[];
	/** Save gate — the caller ANDs in the transient `saving` UI flag. */
	canSave: boolean;
}

/**
 * True when the values-mode draft hides every declared lane — the board
 * would render nothing, so the editor blocks save. An unresolvable or
 * value-less group-by field skips the check (its own validation owns that).
 */
function allLanesHidden(draft: CollectionViewDraft): boolean {
	const field = draft.fields.find((f) => f.key === draft.groupBy.trim());
	if (!field) return false;
	const declared = groupByLaneKeys(field);
	if (declared.length === 0) return false;
	const hidden = new Set(draft.hiddenLanes);
	return declared.every((k) => hidden.has(k));
}

/**
 * Validate the draft: the name is required, table views need at least one
 * column, calendar views need a discriminator (and end field) that serve
 * the surface's window filter, and kanban views need a group-by field that
 * serves the lanes' equality filter (values mode) or complete lanes (custom
 * mode); values mode must also keep at least one lane visible. The
 * capability checks fire only on keys the pickers cannot offer —
 * a stored view whose field lost its `filters:` capability since it was
 * saved. The `saving` flag stays component UI state and is not part of
 * this check.
 */
export function validateDraft(draft: CollectionViewDraft): DraftValidation {
	const nameError = draft.name.trim().length === 0 ? m.list_editor_name_required() : null;
	const columnsError = draft.columns.length === 0 ? m.list_editor_columns_required() : null;
	const discriminator = draft.discriminator.trim();
	const discriminatorError =
		draft.surface !== 'calendar'
			? null
			: discriminator.length === 0
				? m.list_editor_date_required()
				: discriminatorFields(draft.fields).some((f) => f.key === discriminator)
					? null
					: m.list_editor_date_capability();
	const endField = draft.endField.trim();
	const endFieldError =
		draft.surface === 'calendar' &&
		discriminator.length > 0 &&
		endField.length > 0 &&
		!endFields(draft.fields, discriminator).some((f) => f.key === endField)
			? m.list_editor_end_date_capability()
			: null;
	const groupBy = draft.groupBy.trim();
	const groupByError =
		draft.surface !== 'kanban' || draft.kanbanMode !== 'values'
			? null
			: groupBy.length === 0
				? m.list_editor_group_by_required()
				: groupableFields(draft.fields).some((f) => f.key === groupBy)
					? null
					: m.list_editor_group_by_capability();
	const lanesError =
		draft.surface !== 'kanban'
			? null
			: draft.kanbanMode === 'custom' && draft.lanes.length === 0
				? m.list_editor_lanes_required()
				: draft.kanbanMode === 'values' && allLanesHidden(draft)
					? m.list_editor_lanes_all_hidden()
					: null;
	const laneErrors =
		draft.surface === 'kanban' && draft.kanbanMode === 'custom' ? validateLanes(draft.lanes) : [];
	const canSave =
		nameError === null &&
		(draft.surface === 'table'
			? columnsError === null
			: draft.surface === 'calendar'
				? discriminatorError === null && endFieldError === null
				: groupByError === null && lanesError === null && laneErrors.length === 0);
	return {
		nameError,
		columnsError,
		discriminatorError,
		endFieldError,
		groupByError,
		lanesError,
		laneErrors,
		canSave
	};
}
