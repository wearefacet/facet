// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { computeChildOps, type ChildDraft, type ExistingChild } from './childDrafts.js';
import { parseDoctypeDef } from './types.js';

/**
 * Minimal doctype definition reused across cases: one required string,
 * one enum, one integer. Parsed through the real parser so `FieldDef`
 * typing matches what `buildFormPatch`/`buildFormCreate` expect.
 */
const defn = parseDoctypeDef({
	doctype: 'Widget',
	domain: 'test',
	schema_version: 1,
	aggregate_root: true,
	fields: {
		name: { type: 'string', required: true },
		status: {
			type: 'enum',
			values: [
				{ key: 'draft', label: 'Draft' },
				{ key: 'live', label: 'Live' }
			]
		},
		count: { type: 'integer' }
	}
});

function existing(id: string, data: Record<string, unknown>): ExistingChild {
	return { id, data };
}

describe('computeChildOps', () => {
	it('emits no operations when drafts match existing rows', () => {
		const drafts: ChildDraft[] = [{ id: 'a', values: { name: 'Alice', status: 'live', count: 3 } }];
		const rows = [existing('a', { name: 'Alice', status: 'live', count: 3 })];
		expect(computeChildOps(drafts, rows, defn)).toEqual([]);
	});

	it('emits update when a scalar field changed', () => {
		const drafts: ChildDraft[] = [
			{ id: 'a', values: { name: 'Alice', status: 'draft', count: 3 } }
		];
		const rows = [existing('a', { name: 'Alice', status: 'live', count: 3 })];
		const ops = computeChildOps(drafts, rows, defn);
		expect(ops).toHaveLength(1);
		expect(ops[0]).toEqual({ op: 'update', id: 'a', patch: { status: 'draft' } });
	});

	it('coerces integer strings to numbers on update', () => {
		const drafts: ChildDraft[] = [
			{ id: 'a', values: { name: 'Alice', status: 'live', count: '5' } }
		];
		const rows = [existing('a', { name: 'Alice', status: 'live', count: 3 })];
		const ops = computeChildOps(drafts, rows, defn);
		expect(ops).toEqual([{ op: 'update', id: 'a', patch: { count: 5 } }]);
	});

	it('coerces empty string to null (clear signal)', () => {
		const drafts: ChildDraft[] = [
			{ id: 'a', values: { name: 'Alice', status: 'live', count: '' } }
		];
		const rows = [existing('a', { name: 'Alice', status: 'live', count: 3 })];
		const ops = computeChildOps(drafts, rows, defn);
		expect(ops).toEqual([{ op: 'update', id: 'a', patch: { count: null } }]);
	});

	it('skips update when the user reverted the edit', () => {
		// Edit-then-revert: same value, different JS reference path through
		// the form bag. Should produce no operation.
		const drafts: ChildDraft[] = [
			{ id: 'a', values: { name: 'Alice', status: 'live', count: '3' } }
		];
		const rows = [existing('a', { name: 'Alice', status: 'live', count: 3 })];
		expect(computeChildOps(drafts, rows, defn)).toEqual([]);
	});

	it('emits create for a new draft with non-blank values', () => {
		const drafts: ChildDraft[] = [
			{ id: 'new:1', values: { name: 'Bob', status: 'draft', count: '1' } }
		];
		const ops = computeChildOps(drafts, [], defn);
		expect(ops).toEqual([{ op: 'create', content: { name: 'Bob', status: 'draft', count: 1 } }]);
	});

	it('skips create for a new draft that is entirely blank', () => {
		// The user clicked "Add", then left every field empty. We must not
		// create a row that would fail the required-field check downstream.
		// Optional enum defaults are not user-authored edits, but they are not
		// blank either — `buildFormCreate` would emit them. So we only skip when
		// every value (including enum defaults) is blank.
		const drafts: ChildDraft[] = [{ id: 'new:1', values: { name: '', status: '', count: '' } }];
		expect(computeChildOps(drafts, [], defn)).toEqual([]);
	});

	it('emits delete for a tombstoned existing row', () => {
		const drafts: ChildDraft[] = [
			{ id: 'a', values: { name: 'Alice', status: 'live', count: 3 }, deleted: true }
		];
		const rows = [existing('a', { name: 'Alice', status: 'live', count: 3 })];
		expect(computeChildOps(drafts, rows, defn)).toEqual([{ op: 'delete', id: 'a' }]);
	});

	it('drops a tombstoned draft whose id never existed', () => {
		const drafts: ChildDraft[] = [{ id: 'new:1', values: { name: 'Ghost' }, deleted: true }];
		expect(computeChildOps(drafts, [], defn)).toEqual([]);
	});

	it('mixes create / update / delete across a single relation', () => {
		const drafts: ChildDraft[] = [
			{ id: 'a', values: { name: 'Alice', status: 'draft', count: 3 } }, // update
			{ id: 'b', values: { name: 'Bob', status: 'live', count: 1 }, deleted: true }, // delete
			{ id: 'new:2', values: { name: 'Carol', status: 'live', count: '2' } } // create
		];
		const rows = [
			existing('a', { name: 'Alice', status: 'live', count: 3 }),
			existing('b', { name: 'Bob', status: 'live', count: 1 })
		];
		const ops = computeChildOps(drafts, rows, defn);
		expect(ops).toEqual([
			{ op: 'update', id: 'a', patch: { status: 'draft' } },
			{ op: 'delete', id: 'b' },
			{ op: 'create', content: { name: 'Carol', status: 'live', count: 2 } }
		]);
	});

	it('emits create payload with omitted blank values (buildFormCreate contract)', () => {
		// A new row where the user filled only `name` must omit status/count
		// so the backend's required-field validation reports them as missing
		// instead of accepting a present-but-null key.
		const drafts: ChildDraft[] = [{ id: 'new:1', values: { name: 'Bob', status: '', count: '' } }];
		expect(computeChildOps(drafts, [], defn)).toEqual([{ op: 'create', content: { name: 'Bob' } }]);
	});
});
