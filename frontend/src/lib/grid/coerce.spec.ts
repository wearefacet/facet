// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { coerceScalar, parseHexColor, valueEquals } from './coerce.js';
import type { FieldDef } from '$lib/doctype/types.js';

/**
 * Unit tests for the grid's text → value coercion: the stored shapes per
 * field type, the bounds checks, the enum match order, and the no-op
 * equality that keeps an unchanged cell from PATCHing.
 */

const str: FieldDef = { key: 'title', type: 'string', title: 'Title' };
const int: FieldDef = { key: 'age', type: 'integer', title: 'Age' };
const bounded: FieldDef = { key: 'pct', type: 'integer', title: 'Pct', min: 0, max: 100 };
const dur: FieldDef = { key: 'effort', type: 'duration', title: 'Effort' };
const enumField: FieldDef = {
	key: 'status',
	type: 'enum',
	title: 'Status',
	values: [
		{ key: 'needs', label: 'Besoins identifiés' },
		{ key: 'pilot', label: 'Pilote' }
	]
};
const color: FieldDef = { key: 'tint', type: 'color', title: 'Tint' };

describe('coerceScalar — text types', () => {
	it('keeps trimmed text', () => {
		expect(coerceScalar(str, '  Acme  ')).toEqual({ ok: true, value: 'Acme' });
	});

	it('clears on empty input', () => {
		expect(coerceScalar(str, '')).toEqual({ ok: true, value: null });
		expect(coerceScalar(str, '   ')).toEqual({ ok: true, value: null });
	});
});

describe('coerceScalar — integer', () => {
	it('parses whole numbers', () => {
		expect(coerceScalar(int, '42')).toEqual({ ok: true, value: 42 });
		expect(coerceScalar(int, '-7')).toEqual({ ok: true, value: -7 });
	});

	it('rejects non-integers', () => {
		expect(coerceScalar(int, '4.5').ok).toBe(false);
		expect(coerceScalar(int, 'abc').ok).toBe(false);
	});

	it('enforces the declared bounds', () => {
		expect(coerceScalar(bounded, '101').ok).toBe(false);
		expect(coerceScalar(bounded, '-1').ok).toBe(false);
		expect(coerceScalar(bounded, '0')).toEqual({ ok: true, value: 0 });
		expect(coerceScalar(bounded, '100')).toEqual({ ok: true, value: 100 });
	});
});

describe('coerceScalar — duration', () => {
	it('parses free-form durations into seconds', () => {
		const result = coerceScalar(dur, '1h 30m');
		expect(result.ok).toBe(true);
		if (result.ok) expect(result.value).toBe(5400);
	});

	it('clears on empty input', () => {
		expect(coerceScalar(dur, '')).toEqual({ ok: true, value: null });
	});

	it('rejects unparseable text', () => {
		expect(coerceScalar(dur, 'soon').ok).toBe(false);
	});
});

describe('coerceScalar — enum', () => {
	it('matches the exact key first', () => {
		expect(coerceScalar(enumField, 'pilot')).toEqual({ ok: true, value: 'pilot' });
	});

	it('matches the label, then case-insensitively', () => {
		expect(coerceScalar(enumField, 'Pilote')).toEqual({ ok: true, value: 'pilot' });
		expect(coerceScalar(enumField, 'PILOT')).toEqual({ ok: true, value: 'pilot' });
	});

	it('rejects an undeclared key', () => {
		expect(coerceScalar(enumField, 'nope').ok).toBe(false);
	});
});

describe('coerceScalar — color', () => {
	it('normalizes to uppercase #RRGGBB', () => {
		expect(coerceScalar(color, '#3fb39a')).toEqual({ ok: true, value: '#3FB39A' });
	});

	it('expands the 3-digit form', () => {
		expect(coerceScalar(color, '#0af')).toEqual({ ok: true, value: '#00AAFF' });
		expect(parseHexColor('0af')).toBe('#00AAFF');
	});

	it('rejects a non-hex entry', () => {
		expect(coerceScalar(color, 'blue').ok).toBe(false);
		expect(parseHexColor('#12345')).toBeNull();
	});
});

describe('coerceScalar — unsupported types', () => {
	it('fails for picker-only types', () => {
		const money: FieldDef = { key: 'value', type: 'money', title: 'Value' };
		expect(coerceScalar(money, '100').ok).toBe(false);
	});
});

describe('valueEquals', () => {
	it('treats null and undefined as one blank', () => {
		expect(valueEquals(null, undefined)).toBe(true);
		expect(valueEquals(null, '')).toBe(false);
	});

	it('compares objects key-by-key in a stable order', () => {
		expect(valueEquals({ a: 1, b: 2 }, { b: 2, a: 1 })).toBe(true);
		expect(valueEquals({ a: 1 }, { a: 2 })).toBe(false);
		expect(valueEquals({ start: 'x', end: 'y' }, { end: 'y', start: 'x' })).toBe(true);
	});

	it('compares scalars directly', () => {
		expect(valueEquals(42, 42)).toBe(true);
		expect(valueEquals('a', 'b')).toBe(false);
		expect(valueEquals(true, true)).toBe(true);
	});
});
