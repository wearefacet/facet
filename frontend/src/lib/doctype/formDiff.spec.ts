// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { buildFormPatch, buildFormCreate } from './formDiff.js';
import type { DoctypeDef } from './types.js';

// Minimal doctype mirroring the crm.Task shape that surfaced the bug:
// every field is null in the form values (empty inputs), except `status`
// which has a declared default.
const taskDef: DoctypeDef = {
	doctype: 'Task',
	domain: 'crm',
	fields: [
		{ key: 'subject', type: 'string', required: true },
		{ key: 'description', type: 'longtext' },
		{
			key: 'status',
			type: 'enum',
			values: [{ key: 'not_done' }, { key: 'done' }],
			default: 'not_done'
		},
		{ key: 'expected_date', type: 'datetime' },
		{ key: 'completed_at', type: 'datetime' },
		{ key: 'assigned_to', type: 'reference', doctype: 'iam.Account' },
		{ key: 'deal_id', type: 'reference', doctype: 'crm.Deal' },
		{ key: 'qty', type: 'integer' },
		{ key: 'price', type: 'money', currency: 'USD' },
		{ key: 'active', type: 'boolean' },
		{ key: 'effort', type: 'duration' },
		{ key: 'computed', type: 'data', compute: 'compute_computed' },
		// Server-stamped fields: the backend rejects either in input with a
		// 422 (read_only) or expects the stage/adopt flow (secret).
		{ key: 'revision', type: 'integer', read_only: true },
		{ key: 'client_id', type: 'string', read_only: true },
		{ key: 'dept_name', type: 'string', replicate: { via: 'department', field: 'name' } },
		{ key: 'client_secret', type: 'secret', mode: 'sealed' }
	],
	children: [],
	actions: []
};

// Values bag as the create form produces it: empty strings for unfilled
// scalar inputs, the declared default for `status`, `false` for booleans.
const formValues: Record<string, unknown> = {
	subject: '',
	description: '',
	status: 'not_done',
	expected_date: '',
	completed_at: '',
	assigned_to: '',
	deal_id: '',
	qty: '',
	price: '',
	active: false,
	effort: '',
	computed: 'should-be-stripped'
};

describe('buildFormPatch', () => {
	it('coerces empty strings to null (update = clear the field)', () => {
		const patch = buildFormPatch(formValues, taskDef);
		expect(patch.subject).toBe(null);
		expect(patch.description).toBe(null);
		expect(patch.status).toBe('not_done');
		expect(patch.active).toBe(false);
		// Computed (`data`) fields are never sent on update.
		expect('computed' in patch).toBe(false);
	});

	it('omits read-only fields even when the bag carries them (backend 422)', () => {
		// Regression: the persisted content seeded read-only values into the
		// bag and the patch sent them back — `Document::Update` rejects a
		// read_only field in input, which broke the standard edit form for
		// every doctype with server-stamped fields (core.Webhook, app.App, …).
		const patch = buildFormPatch({ ...formValues, revision: 3, client_id: 'app-01' }, taskDef);
		expect('revision' in patch).toBe(false);
		expect('client_id' in patch).toBe(false);
	});

	it('omits replicated fields even when the bag carries them (backend 422)', () => {
		// A replicated field is server-populated from its source document;
		// `Document::Update` rejects a write to it with a 422.
		const patch = buildFormPatch({ ...formValues, dept_name: 'Engineering' }, taskDef);
		expect('dept_name' in patch).toBe(false);
	});

	it('passes a secret stage handle through so the backend can adopt it', () => {
		// Secret fields are NOT skipped: a template form writes the stage
		// handle into the bag and the patch carries it for adoption.
		const patch = buildFormPatch({ ...formValues, client_secret: 'stg_01HANDLE' }, taskDef);
		expect(patch.client_secret).toBe('stg_01HANDLE');
	});
});

describe('buildFormPatch with a persisted baseline (minimal patch)', () => {
	// iam.Roles shape: the update Lua hook refuses any patch that carries
	// `name` (the document id is iam.Roles.<name>), so an untouched save must
	// not ride the key along.
	const roleDef: DoctypeDef = {
		doctype: 'Roles',
		domain: 'iam',
		fields: [
			{ key: 'name', type: 'string', required: true, unique: true },
			{ key: 'level', type: 'integer', required: true },
			{ key: 'description', type: 'longtext' },
			{ key: 'connectivity', type: 'array' },
			{ key: 'assistant_token_budget', type: 'integer' }
		],
		children: [],
		actions: []
	};

	const persistedRole = {
		name: 'editor',
		level: 40,
		description: 'Can edit content',
		connectivity: ['mcp'],
		assistant_token_budget: 100000
	};

	// The bag as `seedEditValues` produces it: a deep clone of the persisted
	// content, so untouched keys hold identical values.
	const seededBag = (): Record<string, unknown> => JSON.parse(JSON.stringify(persistedRole));

	it('omits unchanged keys so an untouched save sends an empty patch', () => {
		// The hook rejects the key itself, so an unchanged `name` must not be
		// re-sent — this is the edit-form regression on iam.Roles / app.App.
		expect(buildFormPatch(seededBag(), roleDef, persistedRole)).toEqual({});
	});

	it('sends only the edited keys', () => {
		const bag = { ...seededBag(), description: 'Can edit everything' };
		const patch = buildFormPatch(bag, roleDef, persistedRole);
		expect(patch).toEqual({ description: 'Can edit everything' });
		expect('name' in patch).toBe(false);
	});

	it('compares coerced values (a retyped identical integer is unchanged)', () => {
		const bag = { ...seededBag(), level: '40' };
		expect(buildFormPatch(bag, roleDef, persistedRole)).toEqual({});
	});

	it('treats a blank input over an absent key as unchanged (both read as "no value")', () => {
		// `emptyValueFor` seeds '' for keys the content lacks; the coerced null
		// equals the absent persisted key, so the save does not write a clear.
		const persisted = { name: 'editor', level: 40 };
		const bag = { ...JSON.parse(JSON.stringify(persisted)), description: '' };
		expect(buildFormPatch(bag, roleDef, persisted)).toEqual({});
	});

	it('still clears a set field (blank over a present value)', () => {
		const bag = { ...seededBag(), description: '' };
		expect(buildFormPatch(bag, roleDef, persistedRole)).toEqual({ description: null });
	});

	it('compares structured values structurally', () => {
		const bag = { ...seededBag(), connectivity: ['mcp'] };
		expect(buildFormPatch(bag, roleDef, persistedRole)).toEqual({});
		const changed = { ...seededBag(), connectivity: ['mcp', 'api'] };
		expect(buildFormPatch(changed, roleDef, persistedRole)).toEqual({
			connectivity: ['mcp', 'api']
		});
	});

	it('compares the coerced money composite against the persisted value', () => {
		const persisted = { price: { value: '9.99', currency: 'EUR' } };
		expect(buildFormPatch({ price: { value: '9.99', currency: 'EUR' } }, taskDef, persisted)).toEqual({});
		const changed = { price: { value: '19.99', currency: 'EUR' } };
		expect(buildFormPatch(changed, taskDef, persisted)).toEqual({
			price: { value: '19.99', currency: 'EUR' }
		});
	});

	it('passes an unknown key through unless it repeats the persisted value', () => {
		const persisted = { extra: 'kept' };
		expect(buildFormPatch({ extra: 'kept' }, taskDef, persisted)).toEqual({});
		expect(buildFormPatch({ extra: 'new' }, taskDef, persisted)).toEqual({ extra: 'new' });
	});
});

describe('buildFormCreate', () => {
	it('omits blank values instead of sending null (lets required validation fire)', () => {
		const body = buildFormCreate(formValues, taskDef);

		// `status` (defaulted) and `active` (explicit false, not blank) survive;
		// everything else blank is omitted so the backend's required-field
		// check reports it as missing.
		expect(body).toEqual({ status: 'not_done', active: false });
		expect('subject' in body).toBe(false);
		expect('description' in body).toBe(false);
		expect('assigned_to' in body).toBe(false);
		expect('qty' in body).toBe(false);
		expect('effort' in body).toBe(false);
	});

	it('keeps explicitly filled scalar values, coerced to their field type', () => {
		const body = buildFormCreate(
			{ ...formValues, subject: 'Sign the contract', qty: '3', active: true },
			taskDef
		);
		expect(body.subject).toBe('Sign the contract');
		expect(body.qty).toBe(3);
		expect(body.active).toBe(true);
		expect(body.status).toBe('not_done');
	});

	it('keeps an explicit false boolean (not blank)', () => {
		const body = buildFormCreate({ ...formValues, active: false }, taskDef);
		expect(body.active).toBe(false);
	});

	it('keeps a zero integer (not blank)', () => {
		const body = buildFormCreate({ ...formValues, qty: '0' }, taskDef);
		expect(body.qty).toBe(0);
	});

	it('treats a blank duration as unset (null on update, omitted on create — B-310)', () => {
		// The form seeds an untouched duration with the '' sentinel. Blank means
		// unset: cleared on update, omitted on create — never a written 0.
		expect(buildFormPatch({ ...formValues, effort: '' }, taskDef).effort).toBe(null);
		expect('effort' in buildFormCreate({ ...formValues, effort: '' }, taskDef)).toBe(false);
	});

	it('keeps an explicit zero duration (0 is a real value, not blank — B-310)', () => {
		// 0 reaches the bag only through a deliberate user entry; it must survive
		// both builders untouched.
		expect(buildFormPatch({ ...formValues, effort: 0 }, taskDef).effort).toBe(0);
		expect(buildFormCreate({ ...formValues, effort: 0 }, taskDef).effort).toBe(0);
	});

	it('coerces a duration string to a number on create', () => {
		const body = buildFormCreate({ ...formValues, effort: '3600' }, taskDef);
		expect(body.effort).toBe(3600);
	});

	it('emits the money composite {value, currency} from a present amount on create', () => {
		const body = buildFormCreate(
			{ ...formValues, price: { value: '4200', currency: 'USD' } },
			taskDef
		);
		expect(body.price).toEqual({ value: '4200', currency: 'USD' });
	});

	it('keeps the money value as a decimal string (never a JS number) on update', () => {
		const patch = buildFormPatch(
			{ ...formValues, price: { value: '9.99', currency: 'EUR' } },
			taskDef
		);
		expect(patch.price).toEqual({ value: '9.99', currency: 'EUR' });
	});

	it('clears a money field when the amount is empty on update', () => {
		const patch = buildFormPatch({ ...formValues, price: '' }, taskDef);
		expect(patch.price).toBe(null);
	});

	it('passes a numeric duration through untouched on update', () => {
		const patch = buildFormPatch({ ...formValues, effort: 7200 }, taskDef);
		expect(patch.effort).toBe(7200);
	});

	it('coerces an integer string to a number on update', () => {
		const patch = buildFormPatch({ ...formValues, qty: '5' }, taskDef);
		expect(patch.qty).toBe(5);
	});

	it('strips computed (`data`) fields on create', () => {
		const body = buildFormCreate(formValues, taskDef);
		expect('computed' in body).toBe(false);
	});

	it('omits read-only fields on create (they are server-stamped)', () => {
		const body = buildFormCreate({ ...formValues, revision: '3', client_id: 'app-01' }, taskDef);
		expect('revision' in body).toBe(false);
		expect('client_id' in body).toBe(false);
	});

	it('omits replicated fields on create (they are server-populated)', () => {
		const body = buildFormCreate({ ...formValues, dept_name: 'Engineering' }, taskDef);
		expect('dept_name' in body).toBe(false);
	});

	it('carries a secret stage handle on create for the adopt flow', () => {
		const body = buildFormCreate({ ...formValues, client_secret: 'stg_01HANDLE' }, taskDef);
		expect(body.client_secret).toBe('stg_01HANDLE');
	});

	it('returns an empty object when nothing is filled and no defaults exist', () => {
		const def: DoctypeDef = {
			doctype: 'D',
			domain: 'crm',
			fields: [
				{ key: 'name', type: 'string', required: true },
				{ key: 'qty', type: 'integer' }
			],
			children: [],
			actions: []
		};
		expect(buildFormCreate({ name: '', qty: '' }, def)).toEqual({});
	});
});

describe('structured fields (object / array / dictionary — B-105)', () => {
	const structDef: DoctypeDef = {
		doctype: 'Product',
		domain: 'shop',
		fields: [
			{ key: 'payload', type: 'object' },
			{ key: 'tags', type: 'array' },
			{ key: 'meta', type: 'dictionary' }
		],
		children: [],
		actions: []
	};

	it('sends the parsed structure, never the raw JSON text', () => {
		const values = { payload: { street: 'Main St' }, tags: ['a', 'b'], meta: { k: 1 } };
		const patch = buildFormPatch(values, structDef);
		expect(patch.payload).toEqual({ street: 'Main St' });
		expect(patch.tags).toEqual(['a', 'b']);
		expect(patch.meta).toEqual({ k: 1 });
	});

	it('omits blank (never-edited) structured fields on create', () => {
		const body = buildFormCreate({ payload: '', tags: '', meta: '' }, structDef);
		expect(body).toEqual({});
	});

	it('clears a blank structured field on update (the cleared sentinel)', () => {
		const patch = buildFormPatch({ payload: '', tags: '', meta: '' }, structDef);
		expect(patch).toEqual({ payload: null, tags: null, meta: null });
	});
});

describe('object field with declared properties (B-183)', () => {
	// crm.Company shape: `address` declares sub-fields, so the form seeds it
	// with the '' sentinel and the object branch must map the blank to null.
	const companyDef: DoctypeDef = {
		doctype: 'Company',
		domain: 'crm',
		fields: [
			{ key: 'name', type: 'string', required: true },
			{
				key: 'address',
				type: 'object',
				properties: [
					{ key: 'street', type: 'string' },
					{ key: 'city', type: 'string' }
				]
			}
		],
		children: [],
		actions: []
	};

	it('sends null for an untouched-empty structured object on update', () => {
		// The bag holds the '' sentinel (the form seeds it); the patch must
		// carry null so the merge patch clears the key instead of failing the
		// backend object check with "address must be an object".
		const patch = buildFormPatch({ name: 'Acme', address: '' }, companyDef);
		expect(patch.address).toBe(null);
	});

	it('sends the full sub-object when the structured object holds a value', () => {
		const patch = buildFormPatch(
			{ name: 'Acme', address: { street: 'Main St', city: 'Oslo' } },
			companyDef
		);
		expect(patch.address).toEqual({ street: 'Main St', city: 'Oslo' });
	});

	it('coerces a blank sub-property to a null member on update', () => {
		// Sub-property blanks follow the scalar rule inside the branch; only a
		// whole-field blank maps to a top-level null.
		const patch = buildFormPatch(
			{ name: 'Acme', address: { street: '', city: 'Oslo' } },
			companyDef
		);
		expect(patch.address).toEqual({ street: null, city: 'Oslo' });
	});

	it('omits a blank structured object on create entirely', () => {
		const body = buildFormCreate({ name: 'Acme', address: '' }, companyDef);
		expect('address' in body).toBe(false);
	});

	it('passes a non-blank non-object through so the backend rejects it honestly', () => {
		const patch = buildFormPatch({ name: 'Acme', address: 'oops' }, companyDef);
		expect(patch.address).toBe('oops');
	});
});

describe('url field normalization', () => {
	const urlDef: DoctypeDef = {
		doctype: 'Contact',
		domain: 'crm',
		fields: [{ key: 'website', type: 'url' }],
		children: [],
		actions: []
	};

	it('prepends the default scheme to a dotted bare host (B-294)', () => {
		expect(buildFormPatch({ website: 'www.acme.com' }, urlDef).website).toBe(
			'https://www.acme.com'
		);
		expect(buildFormCreate({ website: 'acme.io/path' }, urlDef).website).toBe(
			'https://acme.io/path'
		);
	});

	it('sends a dotless scheme-less value verbatim — the backend refuses it (B-294)', () => {
		// Not completed: the same rule `UrlType#normalize` applies, so the
		// raw value reaches the backend and 422s, same as REST.
		expect(buildFormPatch({ website: 'not-a-url' }, urlDef).website).toBe('not-a-url');
		expect(buildFormPatch({ website: 'localhost:3000' }, urlDef).website).toBe('localhost:3000');
	});

	it('keeps an absolute value untouched on create', () => {
		const body = buildFormCreate({ website: 'http://insecure.example' }, urlDef);
		expect(body.website).toBe('http://insecure.example');
	});

	it('trims whitespace around a bare host', () => {
		const patch = buildFormPatch({ website: '  www.acme.com  ' }, urlDef);
		expect(patch.website).toBe('https://www.acme.com');
	});

	it('treats a whitespace-only value as cleared (null on update, omitted on create)', () => {
		expect(buildFormPatch({ website: '   ' }, urlDef).website).toBe(null);
		expect('website' in buildFormCreate({ website: '   ' }, urlDef)).toBe(false);
	});

	it('still clears an empty value on update and omits it on create', () => {
		expect(buildFormPatch({ website: '' }, urlDef).website).toBe(null);
		expect('website' in buildFormCreate({ website: '' }, urlDef)).toBe(false);
	});
});
