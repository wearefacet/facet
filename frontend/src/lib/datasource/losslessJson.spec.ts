// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';

import { parseLosslessJson } from './losslessJson.js';

/**
 * Unit tests for the lossless JSON parse.
 *
 * DocumentDataSource reads every API response through parseLosslessJson.
 * Plain JSON.parse rounds integers past Number.MAX_SAFE_INTEGER to the
 * nearest double, so Int64 values lose digits before render. The parse
 * quotes such literals, so they arrive as exact decimal strings.
 */

describe('parseLosslessJson — integers past the safe range', () => {
	it('keeps the Int64 minimum exact as a string', () => {
		expect(parseLosslessJson('-9223372036854775808')).toBe('-9223372036854775808');
	});

	it('keeps the Int64 maximum exact as a string', () => {
		expect(parseLosslessJson('9223372036854775807')).toBe('9223372036854775807');
	});

	it('keeps the first unsafe integer exact as a string, signed or not', () => {
		expect(parseLosslessJson('9007199254740993')).toBe('9007199254740993');
		expect(parseLosslessJson('-9007199254740993')).toBe('-9007199254740993');
	});

	it('keeps MAX_SAFE_INTEGER itself a number', () => {
		const value = parseLosslessJson('9007199254740991') as number;
		expect(value).toBe(9007199254740991);
		expect(typeof value).toBe('number');
	});

	it('prints the parsed Int64 verbatim through String, like the table cell', () => {
		const value = parseLosslessJson('-9223372036854775808') as string;
		expect(String(value)).toBe('-9223372036854775808');
	});
});

describe('parseLosslessJson — numbers inside the safe range', () => {
	it('keeps small integers numbers', () => {
		const value = parseLosslessJson('[0, 18, -5, 1000000]') as number[];
		expect(value).toEqual([0, 18, -5, 1000000]);
		expect(value.every((v) => typeof v === 'number')).toBe(true);
	});

	it('keeps fraction forms numbers', () => {
		const value = parseLosslessJson('[3.14, -2.5, 2.0]') as number[];
		expect(value).toEqual([3.14, -2.5, 2]);
	});

	it('keeps exponent forms numbers', () => {
		const value = parseLosslessJson('[1e21, 2.5e-3, 9.2e18]') as number[];
		expect(value).toEqual([1e21, 0.0025, 9.2e18]);
	});

	it('keeps negative zero a number', () => {
		const value = parseLosslessJson('-0') as number;
		expect(Object.is(value, -0)).toBe(true);
	});

	it('keeps null, true and false their own values', () => {
		const value = parseLosslessJson('[null, true, false]') as unknown[];
		expect(value).toEqual([null, true, false]);
	});
});

describe('parseLosslessJson — strings', () => {
	it('never touches digits inside a string value', () => {
		const value = parseLosslessJson('{"note":"id 9223372036854775807 stays text"}') as Record<
			string,
			string
		>;
		expect(value.note).toBe('id 9223372036854775807 stays text');
	});

	it('handles an escaped quote around digits inside a string', () => {
		const value = parseLosslessJson('{"esc":"line\\"9223372036854775807\\""}') as Record<
			string,
			string
		>;
		expect(value.esc).toBe('line"9223372036854775807"');
	});

	it('handles a unicode escape that yields a digit inside a string', () => {
		const value = parseLosslessJson('"\\u0039223372036854775807"') as string;
		expect(value).toBe('9223372036854775807');
	});
});

describe('parseLosslessJson — structure', () => {
	it('walks nested objects and arrays', () => {
		const value = parseLosslessJson(
			'{"data":{"rows":[{"v":9223372036854775807},{"v":[9007199254740993]}]},"meta":{"count":2,"more":false}}'
		) as { data: { rows: Array<{ v: unknown }> }; meta: { count: number; more: boolean } };
		expect(value.data.rows[0].v).toBe('9223372036854775807');
		expect(value.data.rows[1].v).toEqual(['9007199254740993']);
		expect(value.meta).toEqual({ count: 2, more: false });
	});

	it('keeps adjacent tokens apart with no whitespace', () => {
		const value = parseLosslessJson('[9007199254740992,"9223372036854775807",18]') as unknown[];
		expect(value[0]).toBe('9007199254740992');
		expect(value[1]).toBe('9223372036854775807');
		expect(value[2]).toBe(18);
	});

	it('mirrors the { data, meta } list envelope of a real response', () => {
		const value = parseLosslessJson(
			'{"data":[{"data":{"balance":-9223372036854775808},"meta":{"id":"hr.Employee.1"}}],"meta":{"count":1,"more":false}}'
		) as { data: Array<{ data: { balance: string }; meta: { id: string } }> };
		expect(String(value.data[0].data.balance)).toBe('-9223372036854775808');
	});

	it('ignores whitespace around tokens', () => {
		const value = parseLosslessJson('  [ 18 , 9007199254740993 ]  ') as unknown[];
		expect(value).toEqual([18, '9007199254740993']);
	});
});

describe('parseLosslessJson — invalid input', () => {
	it('still rejects malformed JSON', () => {
		expect(() => parseLosslessJson('nope')).toThrow(SyntaxError);
		expect(() => parseLosslessJson('[01]')).toThrow(SyntaxError);
		expect(() => parseLosslessJson('{"a":9223372036854775808')).toThrow(SyntaxError);
	});

	it('leaves a leading-zero literal verbatim, so the parse rejects it', () => {
		expect(() => parseLosslessJson('[0079223372036854775808]')).toThrow(SyntaxError);
	});
});
