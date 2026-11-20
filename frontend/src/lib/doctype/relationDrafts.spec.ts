// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import {
	createRelationDrafts,
	DRAFTS_KEY,
	mirrorDraftsToValues,
	newMirrorState
} from './relationDrafts.svelte.js';
import { parseDoctypeDef } from './types.js';
import type { RelationRow } from './relationColumns.js';
import type { ChildDraft } from './childDrafts.js';

/**
 * Draft controller semantics: the rows fallback, tombstone add/remove, and
 * the `values[DRAFTS_KEY]` mirror with its cached-bag identity guarantee.
 *
 * The Vitest server project compiles `.svelte.ts` modules with the server
 * runtime: `$state` becomes a plain variable, `$derived` re-evaluates on
 * each read, and `$effect.pre` is erased — so the controller is exercised
 * synchronously here, and the mirror is driven through
 * {@link mirrorDraftsToValues} (the exact function the component's
 * `$effect.pre` calls). The effect wiring itself is covered by the
 * `EditableAddRow` / `EditableAddRowProxied` story plays.
 */

const def = parseDoctypeDef({
	doctype: 'CandidateExperience',
	domain: 'hr',
	schema_version: 1,
	fields: {
		company: { type: 'string' },
		title: { type: 'string' },
		current: { type: 'boolean' },
		start: { type: 'datetime', default: '2020-01-01T00:00:00Z' },
		note: { type: 'data' }
	}
});

function row(id: string, data: Record<string, unknown>): RelationRow {
	return { meta: { id, display_name: null }, data };
}

const rows: RelationRow[] = [
	row('hr.Candidate.c1.experiences.1', { company: 'Monzo', current: true }),
	row('hr.Candidate.c1.experiences.2', { company: 'Deliveroo', current: false })
];

interface Fixture {
	controller: ReturnType<typeof createRelationDrafts>;
	values: Record<string, unknown>;
	setRows(next: RelationRow[] | null): void;
}

function setup(overrides?: {
	draftsKey?: string;
	isEditable?: boolean;
	rows?: RelationRow[] | null;
	relationDef?: typeof def;
}): Fixture {
	const values: Record<string, unknown> = {};
	let currentRows: RelationRow[] | null = overrides?.rows ?? [];
	const controller = createRelationDrafts({
		draftsKey: () => overrides?.draftsKey ?? 'experiences',
		isEditable: () => overrides?.isEditable ?? true,
		rows: () => currentRows,
		relationDef: () => (overrides && 'relationDef' in overrides ? overrides.relationDef : def),
		values: () => values
	});
	return {
		controller,
		values,
		setRows(next: RelationRow[] | null) {
			currentRows = next;
		}
	};
}

describe('drafts derived — rows fallback', () => {
	it('falls back to rows.map(rowToDraft) while the user has not edited', () => {
		const f = setup({ rows });
		expect(f.controller.drafts.map((d) => d.id)).toEqual([
			'hr.Candidate.c1.experiences.1',
			'hr.Candidate.c1.experiences.2'
		]);
	});

	it('re-derives from fresh rows when the loaded rows change', () => {
		const f = setup({ rows: [] });
		expect(f.controller.drafts).toEqual([]);
		f.setRows(rows);
		expect(f.controller.drafts.map((d) => d.id)).toHaveLength(2);
	});

	it('deep clones row data — draft edits never leak into the rows cache', () => {
		const f = setup({ rows });
		f.controller.drafts[0].values.company = 'Changed';
		expect(rows[0].data.company).toBe('Monzo');
	});

	it('yields an empty list when the relation is not editable', () => {
		const f = setup({ rows, isEditable: false });
		expect(f.controller.drafts).toEqual([]);
	});
});

describe('add / remove with tombstone semantics', () => {
	it('addDraft seeds typed empty values from the relation def', () => {
		const f = setup({ rows: [] });
		f.controller.addDraft();
		const d = f.controller.drafts[0];
		expect(d.id.startsWith('new:')).toBe(true);
		expect(d.values).toEqual({
			company: '',
			title: '',
			current: false,
			start: '2020-01-01T00:00:00Z'
		});
	});

	it('addDraft yields an empty values bag without a def', () => {
		const f = setup({ rows: [], relationDef: undefined });
		f.controller.addDraft();
		expect(f.controller.drafts[0].values).toEqual({});
	});

	it('addDraft stages on top of the current drafts (rows fallback included)', () => {
		const f = setup({ rows });
		f.controller.addDraft();
		expect(f.controller.drafts).toHaveLength(3);
	});

	it('removeDraft tombstones an existing row (kept for the delete op)', () => {
		const f = setup({ rows });
		f.controller.removeDraft('hr.Candidate.c1.experiences.1');
		const d = f.controller.drafts.find(
			(x) => x.id === 'hr.Candidate.c1.experiences.1'
		) as ChildDraft;
		expect(d.deleted).toBe(true);
	});

	it('removeDraft drops a tombstoned new row immediately', () => {
		const f = setup({ rows: [] });
		f.controller.addDraft();
		const newId = f.controller.drafts[0].id;
		f.controller.removeDraft(newId);
		expect(f.controller.drafts).toHaveLength(0);
	});

	it('removeDraft on a new row keeps earlier untouched drafts', () => {
		const f = setup({ rows: [] });
		f.controller.addDraft();
		f.controller.addDraft();
		const first = f.controller.drafts[0].id;
		f.controller.removeDraft(f.controller.drafts[1].id);
		expect(f.controller.drafts.map((d) => d.id)).toEqual([first]);
	});

	it('setDrafts replaces the whole staged list', () => {
		const f = setup({ rows });
		const next: ChildDraft[] = [{ id: 'x', values: { company: 'X' } }];
		f.controller.setDrafts(next);
		expect(f.controller.drafts).toEqual(next);
	});

	it('reset() drops the user drafts — drafts fall back to the loaded rows', () => {
		const f = setup({ rows });
		f.controller.addDraft();
		expect(f.controller.drafts).toHaveLength(3);
		f.controller.reset();
		expect(f.controller.userDrafts).toBeNull();
		expect(f.controller.drafts).toHaveLength(2);
	});
});

describe('mirrorDraftsToValues — values[DRAFTS_KEY] mirror', () => {
	function slotOf(values: Record<string, unknown>, key = 'experiences'): ChildDraft[] {
		return (values[DRAFTS_KEY] as Record<string, ChildDraft[]>)[key];
	}

	it('creates the bag on first mirror and stages the drafts under the key', () => {
		const state = newMirrorState();
		const values: Record<string, unknown> = {};
		mirrorDraftsToValues(state, rows.map(rowToDraftForTest), 'experiences', true, values);
		const bag = values[DRAFTS_KEY] as Record<string, ChildDraft[]>;
		expect(Object.keys(bag)).toEqual(['experiences']);
		expect(slotOf(values)).toHaveLength(2);
	});

	it('mirror identity: the bag object reference survives every mirror run', () => {
		// The risk mitigation named in the plan: the bag is created once on
		// first mirror and every later update writes through the cached
		// reference — the object assigned to `values[DRAFTS_KEY]` must never be
		// replaced, so a save-time reader always sees one stable container.
		const state = newMirrorState();
		const values: Record<string, unknown> = {};
		const first: ChildDraft[] = [{ id: 'a', values: {} }];
		mirrorDraftsToValues(state, first, 'experiences', true, values);
		const bagRef = values[DRAFTS_KEY];

		// Same drafts array — the reference guard skips every write.
		mirrorDraftsToValues(state, first, 'experiences', true, values);
		expect(values[DRAFTS_KEY]).toBe(bagRef);
		expect(slotOf(values)).toBe(first);

		// A user edit produces a new drafts array — the slot is replaced, the
		// bag is not.
		const second: ChildDraft[] = [...first, { id: 'new:1', values: {} }];
		mirrorDraftsToValues(state, second, 'experiences', true, values);
		expect(values[DRAFTS_KEY]).toBe(bagRef);
		expect(slotOf(values)).toBe(second);
		expect(slotOf(values)).toHaveLength(2);

		// The rows refresh path re-derives drafts — same guarantees.
		const third: ChildDraft[] = [{ id: 'b', values: {} }];
		mirrorDraftsToValues(state, third, 'experiences', true, values);
		expect(values[DRAFTS_KEY]).toBe(bagRef);
		expect(slotOf(values)).toBe(third);
	});

	it('mirror identity: the mirror never re-reads the bag through the values proxy', () => {
		// The cached-bag contract: after the first assignment, every later run
		// writes through `state.bag` — `values` itself must never be read back
		// (reading through the Svelte 5 proxy is what re-fired consumer
		// effects and broke user input in the original bug).
		const state = newMirrorState();
		const target: Record<string, unknown> = {};
		const ops: string[] = [];
		const values = new Proxy(target, {
			get(t, prop) {
				ops.push(`get:${String(prop)}`);
				return Reflect.get(t, prop);
			},
			set(t, prop, v) {
				ops.push(`set:${String(prop)}`);
				return Reflect.set(t, prop, v);
			}
		});
		const first: ChildDraft[] = [{ id: 'a', values: {} }];
		mirrorDraftsToValues(state, first, 'k', true, values);
		const second: ChildDraft[] = [{ id: 'b', values: {} }];
		mirrorDraftsToValues(state, second, 'k', true, values);
		expect(ops).toEqual(['set:' + DRAFTS_KEY]);
	});

	it('skips redundant mirrors when the drafts array reference is unchanged', () => {
		const state = newMirrorState();
		const values: Record<string, unknown> = {};
		const drafts: ChildDraft[] = [{ id: 'a', values: {} }];
		mirrorDraftsToValues(state, drafts, 'k', true, values);
		const slotRef = slotOf(values, 'k');
		mirrorDraftsToValues(state, drafts, 'k', true, values);
		mirrorDraftsToValues(state, drafts, 'k', true, values);
		expect(slotOf(values, 'k')).toBe(slotRef);
	});

	it('stages under the draftsKey (filter sources stage by field)', () => {
		const state = newMirrorState();
		const values: Record<string, unknown> = {};
		mirrorDraftsToValues(state, [], 'contact', true, values);
		expect(Object.keys(values[DRAFTS_KEY] as object)).toEqual(['contact']);
	});

	it('writes nothing when the relation is not editable or has no values bag', () => {
		const state = newMirrorState();
		const values: Record<string, unknown> = {};
		mirrorDraftsToValues(state, [], 'k', false, values);
		expect(values[DRAFTS_KEY]).toBeUndefined();
		mirrorDraftsToValues(state, [], 'k', true, undefined);
		expect(values[DRAFTS_KEY]).toBeUndefined();
		expect(state.lastMirrored).toBeUndefined();
	});

	it('fresh artifacts re-create the bag (parent id changed)', () => {
		const state = newMirrorState();
		const values: Record<string, unknown> = {};
		mirrorDraftsToValues(state, [{ id: 'a', values: {} }], 'k', true, values);
		const oldBag = values[DRAFTS_KEY];
		// `controller.reset()` drops user drafts and clears the artifacts;
		// a mirror run afterwards must build a new bag.
		state.bag = null;
		state.lastMirrored = undefined;
		mirrorDraftsToValues(state, [{ id: 'b', values: {} }], 'k', true, values);
		expect(values[DRAFTS_KEY]).not.toBe(oldBag);
	});
});

/** Test helper — mirrors the component's `rowToDraft` usage. */
function rowToDraftForTest(r: RelationRow): ChildDraft {
	return { id: r.meta.id, values: { ...r.data } };
}
