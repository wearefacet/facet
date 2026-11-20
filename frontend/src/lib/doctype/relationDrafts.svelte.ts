// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Draft controller for editable `relation` nodes.
 *
 * Owns the per-instance draft state of one editable relation: the
 * user-staged drafts, the derived list the rows render (falling back to the
 * loaded rows until the user edits), the add / remove mutators with
 * tombstone semantics, and the mirror that stages the drafts under the
 * parent form's `values` bag so `DocumentForm.persistChildDrafts` can read
 * them synchronously at save time.
 *
 * `computeOps()` and `persist()` stay on the component — that is the
 * `DocumentForm` contract (`bind:this`).
 */

import type { DoctypeDef } from './types.js';
import { rowToDraft, seedEmptyDraft, type RelationRow } from './relationColumns.js';
import type { ChildDraft } from './childDrafts.js';

/** Key under the parent form's `values` bag where the drafts are staged. */
export const DRAFTS_KEY = '__relation_drafts__';

export interface RelationDraftsOptions {
	/** Staging key — the relation `rel` (children) or `field` (filter). */
	draftsKey: () => string;
	/** Whether the relation renders editable rows. */
	isEditable: () => boolean;
	/** Loaded rows — the fallback source while the user has not edited. */
	rows: () => RelationRow[] | null;
	/** Relation doctype definition — seeds typed empty values on Add. */
	relationDef: () => DoctypeDef | undefined;
	/** Parent form values bag — receives the `values[DRAFTS_KEY]` mirror. */
	values: () => Record<string, unknown> | undefined;
}

export interface RelationDraftsController {
	/** Effective drafts rendered into the editable list. */
	readonly drafts: ChildDraft[];
	/** User-staged drafts, or `null` while the rows fallback is active. */
	readonly userDrafts: ChildDraft[] | null;
	/** Stage a new set of drafts as the user's authoritative state. */
	setDrafts(next: ChildDraft[]): void;
	/** Append one typed empty draft with a stable `new:` synthetic id. */
	addDraft(): void;
	/** Tombstone a draft; tombstoned `new:` rows drop immediately. */
	removeDraft(id: string): void;
	/** Drop user drafts and the mirror artifacts (parent document changed). */
	reset(): void;
}

/**
 * Mirror artifacts — plain data cached across mirror runs. The bag holds the
 * object once assigned to `values[DRAFTS_KEY]`; `lastMirrored` is the drafts
 * array the last run staged.
 */
export interface RelationDraftsMirrorState {
	bag: Record<string, ChildDraft[]> | null;
	lastMirrored: ChildDraft[] | undefined;
}

export function newMirrorState(): RelationDraftsMirrorState {
	return { bag: null, lastMirrored: undefined };
}

/**
 * One mirror step — stage `drafts` under `values[DRAFTS_KEY]` so
 * `DocumentForm.persistChildDrafts` (which reads
 * `values[DRAFTS_KEY][rel]` synchronously at save time) sees the current
 * state. This is the ONLY code that writes `values[DRAFTS_KEY]`.
 *
 * The write targets the parent's bag; the reactive inputs (`drafts`,
 * `draftsKey`, `isEditable`, `values`) are read by the caller — the
 * component's `$effect.pre`. To avoid a read-then-write cycle on the SAME
 * key (which Svelte 5 detects as `effect_update_depth_exceeded`), the bag is
 * built once on first mirror and the reference is cached in `state`. Later
 * runs write through the cached reference — never by re-reading
 * `values[DRAFTS_KEY]` from the proxy.
 *
 * A standalone function (not inlined into the effect) so the Vitest server
 * project can drive it: `.svelte.ts` modules compile to the server runtime
 * there, where `$effect.pre` is erased. The component calls it from exactly
 * one `$effect.pre`; the storybook plays cover that wiring.
 */
export function mirrorDraftsToValues(
	state: RelationDraftsMirrorState,
	drafts: ChildDraft[],
	draftsKey: string,
	isEditable: boolean,
	values: Record<string, unknown> | undefined
): void {
	if (!isEditable || !values) return;
	// Skip if the array reference has not changed since the last mirror.
	if (state.lastMirrored === drafts) return;
	state.lastMirrored = drafts;
	if (state.bag === null) {
		// First mirror for this component instance — create the bag and slot.
		state.bag = { [draftsKey]: drafts };
		values[DRAFTS_KEY] = state.bag;
	} else {
		// Bag already exists — write through the cached reference.
		state.bag[draftsKey] = drafts;
	}
}

/**
 * Create the draft controller for one editable relation.
 *
 * Call during component initialisation — the mirror below registers an
 * `$effect.pre`, which is only legal inside a component. The option
 * accessors keep the controller reactive: each read tracks the underlying
 * component state, exactly as the inline version did.
 */
export function createRelationDrafts(options: RelationDraftsOptions): RelationDraftsController {
	// User-staged drafts — null until the user adds/removes/types. The derived
	// `drafts` falls back to `rows.map(rowToDraft)` while this stays null so the
	// editable form shows loaded rows without an imperative seeding step.
	let userDrafts = $state<ChildDraft[] | null>(null);
	// Mirror artifacts — plain data so the mirror can cache the bag reference
	// across effect runs without creating a reactive read-then-write cycle.
	// See {@link mirrorDraftsToValues}.
	const mirror = newMirrorState();

	// `drafts` are derived from `rows` (loaded children) until the user edits.
	// Once the user adds / removes / types in a row, `userDrafts` becomes the
	// source of truth. This avoids the imperative `seedDrafts()` write that used
	// to run synchronously inside `load()`'s `$effect` — that write went into
	// `values[DRAFTS_KEY]`, Svelte 5's deep proxy invalidated any consumer that
	// read `values`, and `load()`'s effect (which tracked `isEditable`) re-fired
	// → infinite loop (`effect_update_depth_exceeded`).
	//
	// `load()` only writes `rows` (the component's own `$state`) — never
	// `values`. The `$effect.pre` below mirrors the derived `drafts` into the
	// parent's `values[DRAFTS_KEY]` bag so `DocumentForm.persistChildDrafts`
	// can read it at save time.
	const drafts = $derived<ChildDraft[]>(
		options.isEditable() ? (userDrafts ?? (options.rows() ?? []).map(rowToDraft)) : []
	);

	$effect.pre(() => {
		mirrorDraftsToValues(
			mirror,
			drafts,
			options.draftsKey(),
			options.isEditable(),
			options.values()
		);
	});

	function setDrafts(next: ChildDraft[]) {
		userDrafts = next;
	}

	function addDraft() {
		// Give the new draft a stable synthetic id so Svelte's {#each} keyed
		// loop can track it across edits. Negative-looking prefix avoids
		// colliding with real qualified ids.
		const id = `new:${crypto.randomUUID()}`;
		const empty: Record<string, unknown> = seedEmptyDraft(options.relationDef());
		const next = [...drafts, { id, values: empty }];
		setDrafts(next);
	}

	function removeDraft(id: string) {
		// Tombstone rather than splice — existing rows need a real `delete`
		// op on save. New rows can be dropped outright.
		const next = drafts
			.map((d) => (d.id === id ? { ...d, deleted: true } : d))
			// Drop tombstoned new rows immediately — they never reached the backend.
			.filter((d) => !(d.deleted && d.id.startsWith('new:')));
		setDrafts(next);
	}

	function reset() {
		// Reset the user-edited drafts when the bound parent document changes —
		// otherwise a user's pending edits on candidate A would leak into
		// candidate B. Dropping the cached mirror artifacts makes the
		// `$effect.pre` re-create the bag on the next render — the previous bag
		// referenced drafts from the old parent id.
		userDrafts = null;
		mirror.bag = null;
		mirror.lastMirrored = undefined;
	}

	return {
		get drafts(): ChildDraft[] {
			return drafts;
		},
		get userDrafts(): ChildDraft[] | null {
			return userDrafts;
		},
		setDrafts,
		addDraft,
		removeDraft,
		reset
	};
}
