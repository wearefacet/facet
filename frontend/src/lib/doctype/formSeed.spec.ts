// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { emptyValueFor, seedCreateValues, seedEditValues } from './formSeed.js';
import type { DoctypeDef } from './types.js';

// Minimal doctype that covers every scalar seed shape, plus a computed
// (`data`) field the seeding must skip.
const def: DoctypeDef = {
	doctype: 'Task',
	domain: 'crm',
	fields: [
		{ key: 'subject', type: 'string', required: true },
		{
			key: 'status',
			type: 'enum',
			values: [{ key: 'not_done' }, { key: 'done' }],
			default: 'not_done'
		},
		{ key: 'qty', type: 'integer' },
		{ key: 'price', type: 'money', currency: 'USD' },
		{ key: 'active', type: 'boolean' },
		{ key: 'effort', type: 'duration' },
		{ key: 'payload', type: 'object' },
		{ key: 'tags', type: 'array' },
		{ key: 'meta', type: 'dictionary' },
		{ key: 'computed', type: 'data', compute: 'compute_computed' },
		{ key: 'revision', type: 'integer', read_only: true },
		{ key: 'dept_name', type: 'string', replicate: { via: 'department', field: 'name' } },
		{ key: 'client_secret', type: 'secret', mode: 'sealed' }
	],
	children: [],
	actions: []
};

describe('emptyValueFor', () => {
	it('seeds booleans with false and durations with the blank sentinel (B-310)', () => {
		expect(emptyValueFor({ key: 'active', type: 'boolean' })).toBe(false);
		// An untouched duration means unset — the same '' sentinel as the other
		// scalars. Zero stays a real, explicitly entered value.
		expect(emptyValueFor({ key: 'effort', type: 'duration' })).toBe('');
	});

	it('seeds text-like and string-coerced numeric fields with the blank sentinel', () => {
		expect(emptyValueFor({ key: 'subject', type: 'string' })).toBe('');
		expect(emptyValueFor({ key: 'status', type: 'enum', values: [{ key: 'not_done' }] })).toBe('');
		expect(emptyValueFor({ key: 'qty', type: 'integer' })).toBe('');
		expect(emptyValueFor({ key: 'price', type: 'money', currency: 'USD' })).toBe('');
	});

	it('seeds the structured fields with the blank sentinel (B-105)', () => {
		// The JSON editor binds `value` with a `$bindable('')` fallback, so the
		// bag must hold a defined (blank) value before the form renders.
		expect(emptyValueFor({ key: 'payload', type: 'object' })).toBe('');
		expect(emptyValueFor({ key: 'tags', type: 'array' })).toBe('');
		expect(emptyValueFor({ key: 'meta', type: 'dictionary' })).toBe('');
	});
});

describe('seedCreateValues', () => {
	it('uses the declared default when present, else the neutral empty', () => {
		const bag = seedCreateValues(def);
		expect(bag.status).toBe('not_done');
		expect(bag.active).toBe(false);
		expect(bag.subject).toBe('');
	});

	it('skips computed (data) fields', () => {
		expect('computed' in seedCreateValues(def)).toBe(false);
	});

	it('skips read-only fields (they are server-stamped)', () => {
		const bag = seedCreateValues(def);
		expect('revision' in bag).toBe(false);
	});

	it('skips replicated fields (they are server-populated)', () => {
		const bag = seedCreateValues(def);
		expect('dept_name' in bag).toBe(false);
	});

	it('seeds secret fields like other scalars (the stage handle lands in the bag)', () => {
		const bag = seedCreateValues(def);
		expect(bag.client_secret).toBe('');
	});
});

describe('seedEditValues', () => {
	it('keeps every persisted value, including explicit null', () => {
		const bag = seedEditValues(def, { subject: 'Signed', qty: 3, active: true, status: null });
		expect(bag.subject).toBe('Signed');
		expect(bag.qty).toBe(3);
		expect(bag.active).toBe(true);
		expect(bag.status).toBe(null);
	});

	it('fills scalar keys the content does not contain with the neutral empty', () => {
		// Regression: a sparse content bag (field never set — API-created
		// document) left `bind:checked` bound to `undefined` on the fallback
		// form's Toggle. Svelte throws `props_invalid_value` when a `bind:`
		// value is `undefined` and the target prop has a `$bindable` fallback.
		const bag = seedEditValues(def, { subject: 'Only the name' });
		expect(bag.subject).toBe('Only the name');
		expect(bag.active).toBe(false);
		expect(bag.effort).toBe('');
		expect(bag.qty).toBe('');
	});

	it('neutral-empties every scalar when the content is missing entirely', () => {
		const bag = seedEditValues(def, null);
		expect(bag.subject).toBe('');
		expect(bag.status).toBe('');
		expect(bag.active).toBe(false);
	});

	it('does not materialize declared defaults on edit', () => {
		// `status` has a declared default; the edit seed is the neutral empty so
		// an untouched save cannot write the default into the document.
		expect(seedEditValues(def, {}).status).toBe('');
	});

	it('deep-clones the persisted content (the bag owns its values)', () => {
		const content: Record<string, unknown> = { subject: 'v1' };
		const bag = seedEditValues(def, content);
		bag.subject = 'edited';
		expect(content.subject).toBe('v1');
	});

	it('strips read-only keys the persisted merge re-introduced', () => {
		// The backend stamps read-only fields into the content; seedEditValues
		// merges that content over the seeds. The strip afterwards keeps the
		// bag free of values the patch builder must not send (read_only in
		// input is rejected with a 422).
		const bag = seedEditValues(def, { subject: 'v1', revision: 3 });
		expect('revision' in bag).toBe(false);
		expect(bag.subject).toBe('v1');
	});

	it('strips replicated keys the persisted merge re-introduced', () => {
		// The backend stamps the replicated value into the content; seedEditValues
		// merges that content over the seeds. The strip keeps the bag free of a
		// value the patch builder must not send (replicated in input is a 422).
		const bag = seedEditValues(def, { subject: 'v1', dept_name: 'Engineering' });
		expect('dept_name' in bag).toBe(false);
		expect(bag.subject).toBe('v1');
	});

	it('keeps the persisted secret marker (the stage/adopt flow owns it)', () => {
		const marker = { mode: 'sealed', version: 1, set_at: '2026-01-01T00:00:00Z' };
		const bag = seedEditValues(def, { client_secret: marker });
		expect(bag.client_secret).toEqual(marker);
	});

	it('keeps the persisted structured values and blank-seeds the unset ones (B-105)', () => {
		// The structured fields bind through the JSON editor: a set field shows
		// its stored structure, an unset field binds '' instead of undefined.
		const bag = seedEditValues(def, {
			payload: { street: 'Main St' },
			tags: ['a', 'b']
		});
		expect(bag.payload).toEqual({ street: 'Main St' });
		expect(bag.tags).toEqual(['a', 'b']);
		expect(bag.meta).toBe('');
	});
});
