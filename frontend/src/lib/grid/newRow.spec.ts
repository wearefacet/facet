// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it } from 'vitest';
import type { FieldDef } from '$lib/doctype/types.js';
import type { GridColumn } from './types.js';
import { draftDirty, missingRequired, newRowBody, newRowDefaults } from './newRow.js';

const col = (key: string, extra?: Partial<GridColumn>): GridColumn => ({
	key,
	label: key,
	...extra
});

const field = (key: string, extra?: Partial<FieldDef>): FieldDef => ({
	key,
	type: 'string',
	...extra
});

describe('newRowBody', () => {
	it('keeps filled values and drops empty committed ones', () => {
		expect(newRowBody({ title: 'Deal', status: '', notes: null, count: 0, flag: false })).toEqual({
			title: 'Deal',
			count: 0,
			flag: false
		});
	});

	it('returns an empty body for an empty draft', () => {
		expect(newRowBody({})).toEqual({});
	});
});

describe('newRowDefaults', () => {
	it('collects the writable columns’ declared defaults', () => {
		const columns = [col('title'), col('status'), col('locked', { editable: false })];
		const fields = [
			field('title'),
			field('status', { default: 'needs' }),
			field('locked', { default: 'x' })
		];
		expect(newRowDefaults(columns, fields)).toEqual({ status: 'needs' });
	});

	it('skips read-only fields and empty defaults', () => {
		const columns = [col('a'), col('b'), col('c')];
		const fields = [
			field('a', { default: '', read_only: true }),
			field('b', { default: '' }),
			field('c')
		];
		expect(newRowDefaults(columns, fields)).toEqual({});
	});
});

describe('missingRequired', () => {
	const columns = [col('title'), col('status'), col('notes')];

	it('names the required-no-default fields the draft misses', () => {
		const fields = [
			field('title', { required: true }),
			field('status'),
			field('notes', { required: true, default: 'n/a' })
		];
		expect(missingRequired({}, columns, fields)).toEqual([fields[0]]);
	});

	it('is silent once the draft fills the field', () => {
		const fields = [field('title', { required: true })];
		expect(missingRequired({ title: 'Deal' }, columns, fields)).toEqual([]);
	});

	it('skips non-writable, optional, and defaulted fields', () => {
		const fields = [
			field('title', { required: true, read_only: true }),
			field('status'),
			field('notes', { required: true, default: 'n/a' })
		];
		// title is required but read-only (the grid cannot write it); status
		// is optional; notes is required with a satisfied default.
		expect(missingRequired({}, columns, fields)).toEqual([]);
	});

	it('ignores required fields no column shows', () => {
		const fields = [field('hidden', { required: true })];
		expect(missingRequired({}, columns, fields)).toEqual([]);
	});
});

describe('draftDirty', () => {
	it('is false for an empty draft or one holding only empties', () => {
		expect(draftDirty({})).toBe(false);
		expect(draftDirty({ title: '', notes: null })).toBe(false);
	});

	it('is true once a real value lands — zero and false are values', () => {
		expect(draftDirty({ count: 0 })).toBe(true);
		expect(draftDirty({ flag: false })).toBe(true);
		expect(draftDirty({ title: 'Deal' })).toBe(true);
	});
});
