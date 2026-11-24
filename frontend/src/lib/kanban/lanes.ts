// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Pure lane logic for the kanban listing surface.
 *
 * Everything here is a plain function over the doctype schema and the
 * persisted {@link KanbanLane} shape — no Svelte reactivity, no data
 * access. The surface shell (`Kanban.svelte`) calls {@link lanesFromGroupBy}
 * and {@link applyLaneOverrides} to resolve the board's lanes and
 * {@link mergeLaneFilters} to build each lane's query; the editor calls
 * {@link validateLanes} to gate save and {@link groupByLaneKeys} for the
 * values-mode lane list; {@link laneWriteTarget} computes the write target
 * a drag-and-drop move PATCHes.
 */

import * as m from '$lib/paraglide/messages';
import { hashColor } from '$lib/utils/color.js';
import { humanize, type FieldDef } from '$lib/doctype/types.js';
import type { KanbanLane } from '$lib/collectionView/types.js';

/**
 * Derive the lanes for a values-mode group-by field — one lane per declared
 * enum value, or the True/False pair for a boolean field.
 */
export function lanesFromGroupBy(field: FieldDef): KanbanLane[] {
	return field.type === 'boolean' ? lanesFromBoolean(field) : lanesFromEnum(field);
}

/**
 * The group-by field's lane keys in declaration order — the enum value keys,
 * or `['true', 'false']` for a boolean. The key of a lane is the value its
 * equality filter matches (see {@link laneKey}); the editor and
 * {@link buildConfig} compare the authored order against this list.
 */
export function groupByLaneKeys(field: FieldDef): string[] {
	if (field.type === 'boolean') return ['true', 'false'];
	return (field.values ?? []).map((v) => v.key);
}

/**
 * A values-mode lane's key — the value its single `field__eq` filter
 * matches, or null when the filter is not exactly one equality entry on a
 * string value. Every lane {@link lanesFromGroupBy} derives carries a key;
 * custom lanes generally do not.
 */
export function laneKey(lane: KanbanLane): string | null {
	const entries = Object.entries(lane.filter);
	if (entries.length !== 1) return null;
	const [key, value] = entries[0];
	const idx = key.lastIndexOf('__');
	if (idx < 0 || key.slice(idx + 2) !== 'eq') return null;
	return typeof value === 'string' ? value : null;
}

/**
 * Apply the stored values-mode lane presentation — `lane_order` and
 * `hidden_lanes` — over the derived lanes. Hidden lanes drop out; the
 * remaining lanes sort into the stored order, with any key the order does
 * not list keeping declaration order after the listed ones. Stale keys (the
 * enum changed since the view was saved) are ignored, so the board always
 * renders every visible derived lane.
 */
export function applyLaneOverrides(
	derived: KanbanLane[],
	laneOrder?: string[],
	hiddenLanes?: string[]
): KanbanLane[] {
	const hidden = new Set(hiddenLanes ?? []);
	const visible = derived.filter((lane) => {
		const key = laneKey(lane);
		return key === null || !hidden.has(key);
	});
	if (!laneOrder || laneOrder.length === 0) return visible;
	const byKey = new Map<string, KanbanLane>();
	for (const lane of visible) {
		const key = laneKey(lane);
		if (key !== null) byKey.set(key, lane);
	}
	const out: KanbanLane[] = [];
	const placed = new Set<string>();
	for (const key of laneOrder) {
		const lane = byKey.get(key);
		if (lane && !placed.has(key)) {
			out.push(lane);
			placed.add(key);
		}
	}
	for (const lane of visible) {
		const key = laneKey(lane);
		if (key === null || !placed.has(key)) out.push(lane);
	}
	return out;
}

/**
 * Derive one lane per declared enum value, in declaration order.
 *
 * The lane filter uses the `field__eq` key form (not the bare field key):
 * it keeps the lane filter identical in shape to what the backend and the
 * mock both parse, and it keeps the group-by rename-safe. An enum value
 * without a label falls back to the humanized key — the same form the
 * table derives for the same value. One without a colour falls back to a
 * stable hash colour. Empty or missing `values` returns no lanes.
 */
export function lanesFromEnum(field: FieldDef): KanbanLane[] {
	return (field.values ?? []).map((v) => ({
		label: v.label ?? humanize(v.key),
		color: v.color ?? hashColor(v.key),
		filter: { [`${field.key}__eq`]: v.key }
	}));
}

/**
 * Derive the two lanes of a boolean field: True first (the affirmative
 * lane is the one users look for), each filtering `field__eq` on the wire
 * strings the backend text path parses (`content->>'field' = 'true'`).
 * Colours fall back to the stable hash so both modes stay consistent.
 */
function lanesFromBoolean(field: FieldDef): KanbanLane[] {
	return [
		{
			label: m.list_filter_true(),
			color: hashColor('true'),
			filter: { [`${field.key}__eq`]: 'true' }
		},
		{
			label: m.list_filter_false(),
			color: hashColor('false'),
			filter: { [`${field.key}__eq`]: 'false' }
		}
	];
}

/**
 * Merge the view-level base filter with a lane filter. The base narrows
 * the board as a whole; on an exact filter-key collision the lane wins —
 * the lane definition is the dominant constraint.
 */
export function mergeLaneFilters(
	base: Record<string, unknown>,
	lane: Record<string, unknown>
): Record<string, unknown> {
	return { ...base, ...lane };
}

/**
 * The write target a lane implies for a drag-and-drop move — the PATCH the
 * target lane's drop writes.
 *
 * Returns `{ field, value }` only when the lane filter is exactly one
 * `field__eq` entry and the field exists, is writable (not `read_only` /
 * `write_only`), and is not computed (`data`). Otherwise returns `null` —
 * an expression lane such as `value__lte` has no single value a move can
 * write, so it would not accept drops. Values-mode lanes always carry a
 * write target.
 *
 * A boolean lane's wire value (`'true'` / `'false'`) coerces to a real
 * boolean — document validation rejects the string form on a boolean
 * field, and a move writes through the typed update path.
 */
export function laneWriteTarget(
	lane: KanbanLane,
	fields: FieldDef[]
): { field: string; value: unknown } | null {
	const entries = Object.entries(lane.filter);
	if (entries.length !== 1) return null;
	const [key, value] = entries[0];
	const idx = key.lastIndexOf('__');
	if (idx < 0 || key.slice(idx + 2) !== 'eq') return null;
	const fieldKey = key.slice(0, idx);
	const field = fields.find((f) => f.key === fieldKey);
	if (!field) return null;
	if (field.read_only || field.write_only || field.type === 'data') return null;
	if (field.type === 'boolean' && (value === 'true' || value === 'false')) {
		return { field: fieldKey, value: value === 'true' };
	}
	return { field: fieldKey, value };
}

/**
 * Validation errors for authored custom lanes — one entry per lane with
 * an empty label, an empty (or value-less) filter, or a duplicate label.
 * The editor surfaces these inline and blocks save while any is present.
 */
export function validateLanes(lanes: KanbanLane[]): { index: number; error: string }[] {
	const out: { index: number; error: string }[] = [];
	const seen = new Set<string>();
	lanes.forEach((lane, index) => {
		const label = lane.label.trim();
		if (label.length === 0) {
			out.push({ index, error: m.list_editor_lane_label_required() });
		} else if (seen.has(label)) {
			out.push({ index, error: m.list_editor_lane_label_duplicate() });
		}
		seen.add(label);
		if (isEmptyLaneFilter(lane.filter)) {
			out.push({ index, error: m.list_editor_lane_filter_required() });
		}
	});
	return out;
}

/**
 * A lane filter counts as empty while its expression is incomplete: no
 * key at all, or a value that is still blank (the editor keeps the
 * `field__op` key once the field and operator are chosen, so the controls
 * keep their selection while the value is pending).
 */
function isEmptyLaneFilter(filter: Record<string, unknown>): boolean {
	const values = Object.values(filter);
	if (values.length === 0) return true;
	return values.some((v) =>
		Array.isArray(v)
			? v.some((x) => String(x ?? '').trim().length === 0)
			: String(v ?? '').trim().length === 0
	);
}
