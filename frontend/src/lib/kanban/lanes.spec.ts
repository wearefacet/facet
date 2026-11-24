// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import {
	lanesFromEnum,
	lanesFromGroupBy,
	groupByLaneKeys,
	laneKey,
	applyLaneOverrides,
	mergeLaneFilters,
	laneWriteTarget,
	validateLanes
} from './lanes.js';
import { hashColor } from '$lib/utils/color.js';
import type { FieldDef, EnumValue } from '$lib/doctype/types.js';
import type { KanbanLane } from '$lib/collectionView/types.js';

const enumField = (values: EnumValue[] | undefined, extra: Partial<FieldDef> = {}): FieldDef => ({
	key: 'status',
	type: 'enum',
	...(values !== undefined ? { values } : {}),
	...extra
});

const lane = (label: string, filter: Record<string, unknown>, color?: string): KanbanLane => ({
	label,
	...(color !== undefined ? { color } : {}),
	filter
});

describe('kanban/lanes — pure lane logic', () => {
	describe('lanesFromEnum', () => {
		it('derives one lane per enum value in declaration order', () => {
			const field = enumField([
				{ key: 'open', label: 'Open', color: '#816bb3' },
				{ key: 'won', label: 'Won', color: '#008f77' }
			]);
			expect(lanesFromEnum(field)).toEqual([
				{ label: 'Open', color: '#816bb3', filter: { status__eq: 'open' } },
				{ label: 'Won', color: '#008f77', filter: { status__eq: 'won' } }
			]);
		});

		it('falls back to the humanized key for the label and to hashColor for the colour', () => {
			const field = enumField([{ key: 'in_review' }]);
			const lanes = lanesFromEnum(field);
			expect(lanes).toHaveLength(1);
			expect(lanes[0].label).toBe('In Review');
			expect(lanes[0].color).toBe(hashColor('in_review'));
		});

		it('prefers the declared label over the humanized key', () => {
			const field = enumField([{ key: 'on_hold', label: 'On hold' }]);
			expect(lanesFromEnum(field)[0].label).toBe('On hold');
		});

		it('uses the field key in the equality filter, not a hardcoded one', () => {
			const field: FieldDef = { key: 'stage', type: 'enum', values: [{ key: 'new' }] };
			expect(lanesFromEnum(field)[0].filter).toEqual({ stage__eq: 'new' });
		});

		it('returns an empty list for empty or missing values', () => {
			expect(lanesFromEnum(enumField([]))).toEqual([]);
			expect(lanesFromEnum(enumField(undefined))).toEqual([]);
		});
	});

	describe('lanesFromGroupBy', () => {
		it('delegates an enum field to lanesFromEnum', () => {
			const field = enumField([{ key: 'open', label: 'Open' }]);
			expect(lanesFromGroupBy(field)).toEqual(lanesFromEnum(field));
		});

		it('derives the True/False pair for a boolean field', () => {
			const field: FieldDef = { key: 'completed', type: 'boolean', title: 'Completed' };
			const lanes = lanesFromGroupBy(field);
			expect(lanes).toEqual([
				{ label: 'True', color: hashColor('true'), filter: { completed__eq: 'true' } },
				{ label: 'False', color: hashColor('false'), filter: { completed__eq: 'false' } }
			]);
		});
	});

	describe('groupByLaneKeys', () => {
		it('lists the enum value keys in declaration order', () => {
			const field = enumField([{ key: 'b' }, { key: 'a' }]);
			expect(groupByLaneKeys(field)).toEqual(['b', 'a']);
		});

		it('lists the boolean wire values', () => {
			const field: FieldDef = { key: 'completed', type: 'boolean' };
			expect(groupByLaneKeys(field)).toEqual(['true', 'false']);
		});

		it('returns an empty list for empty or missing values', () => {
			expect(groupByLaneKeys(enumField([]))).toEqual([]);
			expect(groupByLaneKeys(enumField(undefined))).toEqual([]);
		});
	});

	describe('laneKey', () => {
		it('reads the value of the single equality filter', () => {
			expect(laneKey(lane('Open', { status__eq: 'open' }))).toBe('open');
		});

		it('returns null for a multi-key, non-eq, non-string, or empty filter', () => {
			expect(laneKey(lane('Multi', { status__eq: 'open', value__lte: 5 }))).toBeNull();
			expect(laneKey(lane('Band', { value__lte: 5 }))).toBeNull();
			expect(laneKey(lane('N', { value__eq: 5 }))).toBeNull();
			expect(laneKey(lane('Empty', {}))).toBeNull();
		});
	});

	describe('applyLaneOverrides', () => {
		const derived = (): KanbanLane[] => [
			lane('Open', { status__eq: 'open' }),
			lane('Won', { status__eq: 'won' }),
			lane('Lost', { status__eq: 'lost' })
		];

		it('keeps declaration order without overrides', () => {
			expect(applyLaneOverrides(derived())).toEqual(derived());
			expect(applyLaneOverrides(derived(), [], [])).toEqual(derived());
		});

		it('orders the lanes by the stored order', () => {
			const out = applyLaneOverrides(derived(), ['lost', 'open', 'won']);
			expect(out.map((l) => l.label)).toEqual(['Lost', 'Open', 'Won']);
		});

		it('hides the stored keys', () => {
			const out = applyLaneOverrides(derived(), undefined, ['won']);
			expect(out.map((l) => l.label)).toEqual(['Open', 'Lost']);
		});

		it('appends keys the order does not list, keeping declaration order', () => {
			const out = applyLaneOverrides(derived(), ['won']);
			expect(out.map((l) => l.label)).toEqual(['Won', 'Open', 'Lost']);
		});

		it('ignores stale order and hidden keys the field no longer declares', () => {
			const out = applyLaneOverrides(derived(), ['ghost', 'lost', 'open'], ['ghost', 'open']);
			expect(out.map((l) => l.label)).toEqual(['Lost', 'Won']);
		});

		it('never lists a lane twice on a duplicated order entry', () => {
			const out = applyLaneOverrides(derived(), ['open', 'open', 'won']);
			expect(out.map((l) => l.label)).toEqual(['Open', 'Won', 'Lost']);
		});

		it('keeps a lane without a key visible and unplaced', () => {
			const withExpression = [...derived(), lane('Low', { probability__lt: 50 })];
			const out = applyLaneOverrides(withExpression, ['lost']);
			expect(out.map((l) => l.label)).toEqual(['Lost', 'Open', 'Won', 'Low']);
		});
	});

	describe('mergeLaneFilters', () => {
		it('merges the base filter with the lane filter', () => {
			expect(
				mergeLaneFilters({ status__ne: 'abandoned', owner_id__eq: 'a' }, { probability__lt: 50 })
			).toEqual({ status__ne: 'abandoned', owner_id__eq: 'a', probability__lt: 50 });
		});

		it('lets the lane key win on an exact collision', () => {
			expect(mergeLaneFilters({ status__eq: 'open' }, { status__eq: 'won' })).toEqual({
				status__eq: 'won'
			});
		});

		it('keeps different operators on the same field (both apply)', () => {
			expect(mergeLaneFilters({ status__ne: 'abandoned' }, { status__eq: 'open' })).toEqual({
				status__ne: 'abandoned',
				status__eq: 'open'
			});
		});

		it('returns the lane alone for an empty base', () => {
			expect(mergeLaneFilters({}, { status__eq: 'won' })).toEqual({ status__eq: 'won' });
		});
	});

	describe('laneWriteTarget', () => {
		const fields: FieldDef[] = [
			{ key: 'status', type: 'enum' },
			{ key: 'value', type: 'money' },
			{ key: 'completed', type: 'boolean' },
			{ key: 'weight', type: 'data', compute: 'w' },
			{ key: 'locked', type: 'enum', read_only: true },
			{ key: 'masked', type: 'enum', write_only: true }
		];

		it('resolves a single-eq lane to its field and value', () => {
			expect(laneWriteTarget(lane('Open', { status__eq: 'open' }), fields)).toEqual({
				field: 'status',
				value: 'open'
			});
		});

		it('coerces a boolean lane wire value to a real boolean', () => {
			// Document validation rejects the string form on a boolean field —
			// the move must write the typed value.
			expect(laneWriteTarget(lane('Done', { completed__eq: 'true' }), fields)).toEqual({
				field: 'completed',
				value: true
			});
			expect(laneWriteTarget(lane('Todo', { completed__eq: 'false' }), fields)).toEqual({
				field: 'completed',
				value: false
			});
		});

		it('rejects a multi-key filter', () => {
			expect(laneWriteTarget(lane('Open', { status__eq: 'open', value__lte: 50 }), fields)).toBe(
				null
			);
		});

		it('rejects a non-eq operator', () => {
			expect(laneWriteTarget(lane('Low', { value__lte: 50 }), fields)).toBe(null);
		});

		it('rejects an unknown field', () => {
			expect(laneWriteTarget(lane('Ghost', { ghost__eq: 'x' }), fields)).toBe(null);
		});

		it('rejects a read_only field', () => {
			expect(laneWriteTarget(lane('Locked', { locked__eq: 'x' }), fields)).toBe(null);
		});

		it('rejects a write_only field', () => {
			expect(laneWriteTarget(lane('Masked', { masked__eq: 'x' }), fields)).toBe(null);
		});

		it('rejects a computed (data) field', () => {
			expect(laneWriteTarget(lane('Weight', { weight__eq: 1 }), fields)).toBe(null);
		});

		it('rejects an empty filter', () => {
			expect(laneWriteTarget(lane('Empty', {}), fields)).toBe(null);
		});
	});

	describe('validateLanes', () => {
		it('returns no errors for well-formed lanes', () => {
			expect(
				validateLanes([
					lane('Low', { probability__lt: 50 }),
					lane('High', { probability__gte: 50 })
				])
			).toEqual([]);
		});

		it('flags an empty label', () => {
			const errors = validateLanes([lane('  ', { status__eq: 'open' })]);
			expect(errors).toHaveLength(1);
			expect(errors[0].index).toBe(0);
			expect(errors[0].error.length).toBeGreaterThan(0);
		});

		it('flags an empty filter', () => {
			const errors = validateLanes([lane('Open', {})]);
			expect(errors).toHaveLength(1);
			expect(errors[0].index).toBe(0);
		});

		it('flags a filter whose value is still blank', () => {
			expect(validateLanes([lane('Open', { status__eq: '' })])).toHaveLength(1);
			expect(validateLanes([lane('Band', { value__between: ['USD 1', ''] })])).toHaveLength(1);
			expect(validateLanes([lane('Full', { status__eq: 'open' })])).toEqual([]);
		});

		it('flags a duplicate label on the later lane', () => {
			const errors = validateLanes([lane('Same', { a__eq: 1 }), lane('Same', { b__eq: 2 })]);
			expect(errors).toHaveLength(1);
			expect(errors[0].index).toBe(1);
		});

		it('reports both label and filter problems for a broken lane', () => {
			const errors = validateLanes([lane('', {})]);
			expect(errors).toHaveLength(2);
		});

		it('returns no errors for an empty lane list', () => {
			expect(validateLanes([])).toEqual([]);
		});
	});
});
