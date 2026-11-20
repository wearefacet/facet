// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it } from 'vitest';
import {
	ALL_OPERATORS,
	controlKindFor,
	MAX_IN_VALUES,
	operatorLabel,
	parentFieldDef,
	operatorsFor
} from './filters.js';
import type { FieldDef } from './types.js';
import type { DoctypeDef } from './types.js';

function doctypeDef(overrides: Partial<DoctypeDef>): DoctypeDef {
	return {
		doctype: 'SparePart',
		domain: 'm',
		fields: [],
		children: [],
		actions: [],
		...overrides
	};
}

function field(overrides: Partial<FieldDef>): FieldDef {
	return { key: 'f', type: 'string', title: 'F', ...overrides };
}

describe('operator vocabulary', () => {
	it('mirrors the backend `Operator` declaration order', () => {
		// `src/doctype/operator.cr`: Eq, Ne, Gt, Gte, Lt, Lte, Between, In,
		// Match, (range operators), Currency. The bar renders the subset that
		// pairs with a value control it has; the range operators stay out for
		// now, `currency` renders the currency picker.
		expect(ALL_OPERATORS).toEqual([
			'eq',
			'ne',
			'gt',
			'gte',
			'lt',
			'lte',
			'between',
			'in',
			'match',
			'currency'
		]);
	});

	it('caps __in at the backend bound', () => {
		// Mirrors `Util::FilterSet::MAX_IN_VALUES`; a longer array degrades to
		// an always-false clause, so the bar disables picks at the limit.
		expect(MAX_IN_VALUES).toBe(100);
	});

	it('offers gt/lt on a field that declares the comparison family', () => {
		const f = field({
			type: 'integer',
			operators: ['eq', 'ne', 'gt', 'gte', 'lt', 'lte', 'between']
		});
		expect(operatorsFor(f)).toEqual(['eq', 'ne', 'gt', 'gte', 'lt', 'lte', 'between']);
	});

	it('drops gt/lt when the field metadata does not declare them', () => {
		const f = field({ type: 'datetime', operators: ['eq', 'gte', 'lte', 'between'] });
		expect(operatorsFor(f)).toEqual(['eq', 'gte', 'lte', 'between']);
	});

	it('labels gt/lt with the comparison symbols', () => {
		const f = field({ type: 'integer' });
		expect(operatorLabel('gt', f)).toBe('>');
		expect(operatorLabel('lt', f)).toBe('<');
	});

	it('renders gt/lt with the same type-driven controls as gte/lte', () => {
		expect(controlKindFor(field({ type: 'integer' }), 'gt')).toBe('number');
		expect(controlKindFor(field({ type: 'money' }), 'lt')).toBe('number');
		expect(controlKindFor(field({ type: 'datetime' }), 'gt')).toBe('datetime');
		expect(controlKindFor(field({ type: 'string' }), 'lt')).toBe('text');
	});

	it('offers in only when the field metadata declares it', () => {
		const f = field({ type: 'enum', operators: ['eq', 'ne', 'in'] });
		expect(operatorsFor(f)).toEqual(['eq', 'ne', 'in']);
		const g = field({ type: 'enum', operators: ['eq', 'ne'] });
		expect(operatorsFor(g)).not.toContain('in');
	});

	it('labels in as "is any of", beside the enum is/is-not words', () => {
		expect(operatorLabel('in', field({ type: 'enum' }))).toBe('is any of');
	});

	it('renders in on an enum with the multi-select control', () => {
		expect(controlKindFor(field({ type: 'enum' }), 'in')).toBe('enum-multi');
		// The backend derives `in` for enum fields; other types fall back to
		// the text control (a degenerate def — the metadata never offers it).
		expect(controlKindFor(field({ type: 'string' }), 'in')).toBe('text');
	});

	it('renders a boolean with the True/False dropdown and is/is-not words', () => {
		// The backend derives only eq/ne for a boolean — the two-state filter
		// reads as is / is not, the enum/reference words.
		expect(controlKindFor(field({ type: 'boolean' }), 'eq')).toBe('boolean');
		expect(controlKindFor(field({ type: 'boolean' }), 'ne')).toBe('boolean');
		expect(operatorLabel('eq', field({ type: 'boolean' }))).toBe('is');
		expect(operatorLabel('ne', field({ type: 'boolean' }))).toBe('is not');
	});
});

describe('parentFieldDef', () => {
	it('synthesizes the parent filter for an owned-child doctype', () => {
		const def = parentFieldDef(doctypeDef({ member_of: 'Machine' }));
		expect(def).toEqual({
			key: 'parent_id',
			type: 'reference',
			title: 'Machine',
			doctype: 'm.Machine',
			operators: ['eq']
		});
	});

	it('returns undefined for an aggregate root', () => {
		expect(parentFieldDef(doctypeDef({ aggregate_root: true }))).toBeUndefined();
	});

	it('returns undefined without a domain', () => {
		expect(parentFieldDef(doctypeDef({ member_of: 'Machine', domain: '' }))).toBeUndefined();
	});

	it('returns undefined without a doctype', () => {
		expect(parentFieldDef(undefined)).toBeUndefined();
	});
});
