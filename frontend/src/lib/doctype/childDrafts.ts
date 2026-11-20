// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Child-draft staging for editable `relation` nodes.
 *
 * When a `relation` node on a parent's `kind: form` template is marked
 * `editable: true`, the parent `DocumentForm` renders each child row using
 * the relation doctype's `form` template and stages the user's edits into a
 * `ChildDraft[]`. On parent save, after the parent document persists, the
 * form walks each relation's drafts and computes the create / update / delete
 * operations to issue against `doc(parentId).children(rel)`.
 *
 * The contract mirrors the backend's event-sourcing model: each child is a
 * separate projection with its own mutation history, so a composite edit is a
 * sequence of independent mutations, not a single transactional one. Partial
 * failures are reported per-row by {@link ChildSaveOutcome} — successful
 * creates/updates commit, and any remaining drafts for a failed relation are
 * not retried.
 */

import { buildFormCreate, buildFormPatch, sameValue } from './formDiff.js';
import type { DoctypeDef } from './types.js';

/** Stable identifier for a draft row. `-1` (or any negative id) marks a new row. */
export type DraftId = string;

/** A staged child row inside an editable relation. */
export interface ChildDraft {
	/**
	 * Client-side id. Negative ("-1", "-2", …) or prefixed "new:" for rows
	 * that have no persisted child yet; otherwise the child's qualified id.
	 */
	id: DraftId;
	/** Edited values bag — same shape as the parent form's `values`. */
	values: Record<string, unknown>;
	/** Whether the user marked the row for removal. */
	deleted?: boolean;
}

/** A computed mutation to apply to the child collection. */
export type ChildOp =
	| { op: 'create'; content: Record<string, unknown> }
	| { op: 'update'; id: string; patch: Record<string, unknown> }
	| { op: 'delete'; id: string };

/** The rows the relation currently holds (from `children(rel).list()`). */
export interface ExistingChild {
	id: string;
	data: Record<string, unknown>;
}

/**
 * Diff a draft list against the existing child rows and produce the per-row
 * operations to issue on save.
 *
 * Rules:
 *  - A draft with `deleted: true` whose `id` references an existing row → `delete`.
 *  - A draft with `deleted: true` whose `id` does not exist → dropped (no-op).
 *  - A draft with no existing match (new id) and non-blank values → `create`.
 *  - A draft pointing at an existing row with changed values → `update`.
 *  - A draft pointing at an existing row with unchanged values → no-op.
 *
 * The `update` patch is filtered to only the fields whose coerced value
 * differs from the stored value — untouched fields are not re-sent, so the
 * backend's deep-merge does not rewrite them and the audit log stays clean.
 * Empty strings are coerced to `null` (the documented "clear field" signal). The
 * create payload uses {@link buildFormCreate} so empty values are omitted and
 * the backend reports missing required fields as a clean 422.
 */
export function computeChildOps(
	drafts: ChildDraft[],
	existing: ExistingChild[],
	def: DoctypeDef
): ChildOp[] {
	const existingById = new Map(existing.map((r) => [r.id, r] as const));
	const ops: ChildOp[] = [];

	for (const draft of drafts) {
		const current = existingById.get(draft.id);

		// Tombstoned draft: delete if it existed, drop if it never did.
		if (draft.deleted) {
			if (current) ops.push({ op: 'delete', id: current.id });
			continue;
		}

		if (!current) {
			// New row: skip if the draft is entirely blank (user added a row
			// then left it empty — treat as a no-op so a stray empty draft on
			// a brand-new parent doesn't fail validation).
			if (isBlankDraft(draft.values)) continue;
			ops.push({ op: 'create', content: buildFormCreate(draft.values, def) });
			continue;
		}

		// Existing row: build the full coerced patch via `buildFormPatch`, then
		// filter to only the fields whose value actually changed vs the stored
		// row. A reverted edit produces an empty patch → no operation.
		const fullPatch = buildFormPatch(draft.values, def);
		const changedPatch: Record<string, unknown> = {};
		for (const [key, next] of Object.entries(fullPatch)) {
			if (!sameValue(next, current.data[key])) changedPatch[key] = next;
		}
		if (Object.keys(changedPatch).length > 0) {
			ops.push({ op: 'update', id: current.id, patch: changedPatch });
		}
	}

	return ops;
}

/**
 * Result of persisting a single relation's drafts.
 *
 * The form reports per-relation outcomes to the user; a relation with any
 * `errors` is surfaced in the save banner, while relations that saved cleanly
 * do not clutter the UI.
 */
export interface ChildSaveOutcome {
	/** The relationship key the drafts were staged under. */
	rel: string;
	/** Human-readable label copied from the relation node. */
	label: string;
	/** Per-row error messages keyed by draft id (or a synthetic `-1` for create). */
	errors: Record<string, string>;
	/** Number of operations that completed successfully. */
	saved: number;
}

/**
 * Whether a draft's values are entirely blank (no field holds a meaningful
 * value). Used to skip create on a row the user added then abandoned.
 *
 * The check is intentionally shallow: an object/branch left empty is blank,
 * but a populated sub-object is not. Booleans count as non-blank when `true`.
 */
function isBlankDraft(values: Record<string, unknown>): boolean {
	for (const v of Object.values(values)) {
		if (v === null || v === undefined || v === '') continue;
		if (v === false) continue;
		if (Array.isArray(v) && v.length === 0) continue;
		if (typeof v === 'object' && !Array.isArray(v)) {
			if (Object.keys(v as Record<string, unknown>).length === 0) continue;
			// Any populated sub-object is treated as a real edit.
			return false;
		}
		return false;
	}
	return true;
}

/**
 * Equality check between a coerced patch value and the stored value. Both
 * sides are normalised to `null` for absent/undefined so a "cleared" field
 * (coerced to `null`) compares equal to a previously-absent key. Composite
 * values are compared by JSON serialisation — sufficient for the object /
 * array shapes the form diff produces.
 */
