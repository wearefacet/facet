// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import {
	coerceScalar,
	coercePaste,
	parseDecimalText,
	parseHexColor,
	valueEquals
} from './coerce.js';
import type { FieldDef } from '$lib/doctype/types.js';

/**
 * Unit tests for the grid's text → value coercion: the stored shapes per
 * field type, the bounds checks, the enum match order, and the no-op
 * equality that keeps an unchanged cell from PATCHing — plus the paste-side
 * coercion (`coercePaste`) that accepts every form the copy side emits and
 * the locale-shaped decimals Excel pastes.
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

describe('parseDecimalText', () => {
	it('keeps the canonical decimal shape', () => {
		expect(parseDecimalText('1200.50')).toBe('1200.50');
		expect(parseDecimalText('1200')).toBe('1200');
		expect(parseDecimalText('-1200')).toBe('-1200');
	});

	it('strips spaces and the app grouping mark', () => {
		expect(parseDecimalText('1 234.56')).toBe('1234.56');
		expect(parseDecimalText('1\u00A0234,56')).toBe('1234.56');
		expect(parseDecimalText("1'234.56")).toBe('1234.56');
	});

	it('resolves the rightmost mark as the decimal when both appear', () => {
		expect(parseDecimalText('1,234.56')).toBe('1234.56');
		expect(parseDecimalText('1.234,56')).toBe('1234.56');
		expect(parseDecimalText('1.234.567,89')).toBe('1234567.89');
	});

	it('reads a lone comma as the decimal with 1–2 trailing digits', () => {
		expect(parseDecimalText('1234,56')).toBe('1234.56');
		expect(parseDecimalText('12,5')).toBe('12.5');
	});

	it('reads Excel thousands grouping as grouping', () => {
		expect(parseDecimalText('1,234')).toBe('1234');
		expect(parseDecimalText('1,234,567')).toBe('1234567');
		expect(parseDecimalText('-1,234')).toBe('-1234');
	});

	it('rejects ambiguous or non-numeric text', () => {
		expect(parseDecimalText('1234,5678')).toBeNull();
		expect(parseDecimalText('1.234.567')).toBeNull();
		expect(parseDecimalText('abc')).toBeNull();
		expect(parseDecimalText('1200 EUR')).toBeNull();
	});
});

describe('coercePaste', () => {
	const money: FieldDef = { key: 'value', type: 'money', title: 'Value', currency: 'EUR' };
	const date: FieldDef = { key: 'close_date', type: 'date', title: 'Close' };
	const datetime: FieldDef = { key: 'due_at', type: 'datetime', title: 'Due' };
	const period: FieldDef = { key: 'term', type: 'period', title: 'Term' };
	const dateperiod: FieldDef = { key: 'sprint', type: 'dateperiod', title: 'Sprint' };
	const bool: FieldDef = { key: 'won', type: 'boolean', title: 'Won' };
	const ref: FieldDef = { key: 'owner', type: 'reference', title: 'Owner' };

	it('clears on an empty cell', () => {
		expect(coercePaste(str, '')).toEqual({ ok: true, value: null });
		expect(coercePaste(money, '  ')).toEqual({ ok: true, value: null });
		expect(coercePaste(bool, '')).toEqual({ ok: true, value: null });
	});

	it('builds the money object, keeping the cell currency', () => {
		expect(coercePaste(money, '1250.5')).toEqual({
			ok: true,
			value: { value: '1250.5', currency: 'EUR' }
		});
		expect(
			coercePaste(money, '1,200.00', { current: { value: '130000', currency: 'USD' } })
		).toEqual({
			ok: true,
			value: { value: '1200.00', currency: 'USD' }
		});
		expect(coercePaste(money, '1234,56')).toEqual({
			ok: true,
			value: { value: '1234.56', currency: 'EUR' }
		});
		expect(coercePaste(money, 'cent').ok).toBe(false);
	});

	it('takes dates verbatim in the ISO calendar form', () => {
		expect(coercePaste(date, '2026-09-30')).toEqual({ ok: true, value: '2026-09-30' });
		expect(coercePaste(date, '2026-02-30').ok).toBe(false);
		expect(coercePaste(date, '30/09/2026').ok).toBe(false);
	});

	it('normalizes datetimes to UTC — offset, wall time, date only', () => {
		expect(coercePaste(datetime, '2026-09-30T14:30:00+02:00')).toEqual({
			ok: true,
			value: '2026-09-30T12:30:00.000Z'
		});
		expect(coercePaste(datetime, '2026-09-30 14:30', { timezone: 'UTC' })).toEqual({
			ok: true,
			value: '2026-09-30T14:30:00.000Z'
		});
		expect(coercePaste(datetime, '2026-09-30T16:30', { timezone: 'Europe/Paris' })).toEqual({
			ok: true,
			value: '2026-09-30T14:30:00.000Z'
		});
		expect(coercePaste(datetime, '2026-09-30', { timezone: 'UTC' })).toEqual({
			ok: true,
			value: '2026-09-30T00:00:00.000Z'
		});
		expect(coercePaste(datetime, 'soon').ok).toBe(false);
	});

	it('splits range cells on the copy arrow', () => {
		expect(
			coercePaste(period, '2026-11-01T00:00:00Z → 2027-01-31T23:59:59Z', { timezone: 'UTC' })
		).toEqual({
			ok: true,
			value: { start: '2026-11-01T00:00:00.000Z', end: '2027-01-31T23:59:59.000Z' }
		});
		expect(coercePaste(dateperiod, '2026-12-01 → 2026-12-21')).toEqual({
			ok: true,
			value: { start: '2026-12-01', end: '2026-12-21' }
		});
		expect(coercePaste(period, '2026-11-01T00:00:00Z').ok).toBe(false);
		expect(coercePaste(dateperiod, '2026-02-30 → 2026-03-01').ok).toBe(false);
	});

	it('reads booleans in any case', () => {
		expect(coercePaste(bool, 'TRUE')).toEqual({ ok: true, value: true });
		expect(coercePaste(bool, 'false')).toEqual({ ok: true, value: false });
		expect(coercePaste(bool, 'vrai').ok).toBe(false);
	});

	it('takes references as the raw stored id', () => {
		expect(coercePaste(ref, 'crm.GridContact.1')).toEqual({ ok: true, value: 'crm.GridContact.1' });
		expect(coercePaste(ref, '')).toEqual({ ok: true, value: null });
	});

	it('normalizes grouped integers then applies the bounds', () => {
		expect(coercePaste(int, '1,200')).toEqual({ ok: true, value: 1200 });
		expect(coercePaste(int, '12.5').ok).toBe(false);
		expect(coercePaste(bounded, '1,101').ok).toBe(false);
	});

	it('delegates the remaining types to coerceScalar', () => {
		expect(coercePaste(str, '  Acme  ')).toEqual({ ok: true, value: 'Acme' });
		expect(coercePaste(dur, '11700')).toEqual({ ok: true, value: 11700 });
		expect(coercePaste(dur, '2h 30m')).toEqual({ ok: true, value: 9000 });
		expect(coercePaste(enumField, 'PILOT')).toEqual({ ok: true, value: 'pilot' });
		expect(coercePaste(color, '#3fb39a')).toEqual({ ok: true, value: '#3FB39A' });
	});
});
