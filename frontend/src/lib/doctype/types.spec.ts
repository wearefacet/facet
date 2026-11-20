// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { serializeDoctypeDef } from './serialize.js';
import { parseDoctypeDef, actionStateAllowed } from './types.js';
import type { DoctypeDef } from './types.js';

// Round-trip property: parse then serialize should preserve the keys the
// editor surfaces. This guards against schema drift between the editor's
// working copy and the `PUT /Api/core/DocType/:id` body it sends on save.
describe('serializeDoctypeDef — round-trip with parseDoctypeDef', () => {
	it('round-trips a minimal doctype with no fields', () => {
		const raw = { doctype: 'Task', domain: 'crm', fields: {} };
		const parsed = parseDoctypeDef(raw);
		const out = serializeDoctypeDef(parsed, raw);
		expect(out.doctype).toBe('Task');
		expect(out.domain).toBe('crm');
		expect(out.fields).toEqual({});
	});

	it('round-trips fields, preserving all set properties and dropping editor-only `key`', () => {
		const raw = {
			doctype: 'Deal',
			domain: 'crm',
			fields: {
				subject: { type: 'string', required: true, title: 'Subject' },
				status: {
					type: 'enum',
					values: [{ key: 'open' }, { key: 'won' }, { key: 'lost' }],
					default: 'open'
				},
				amount: { type: 'money', currency: 'USD', min: 0 },
				assignee: { type: 'reference', doctype: 'iam.Account', collection: false }
			}
		};
		const parsed = parseDoctypeDef(raw);
		expect(parsed.fields).toHaveLength(4);
		const out = serializeDoctypeDef(parsed, raw);
		// Field keys come back as object keys, not as a `key` property on each entry.
		expect(out.fields).toEqual(raw.fields);
		expect((out.fields as Record<string, Record<string, unknown>>).subject).not.toHaveProperty(
			'key'
		);
	});

	it('round-trips children and actions', () => {
		const raw = {
			doctype: 'Order',
			domain: 'sales',
			fields: {},
			children: {
				lines: { doctype: 'OrderLine', collection: true, description: 'Line items' }
			},
			actions: {
				submit: {
					args: { note: { type: 'string', required: false } },
					description: 'Submit the order'
				}
			}
		};
		const parsed = parseDoctypeDef(raw);
		const out = serializeDoctypeDef(parsed, raw);
		expect(out.children).toEqual(raw.children);
		expect(out.actions).toEqual(raw.actions);
	});

	it('round-trips the action state gate (B-323)', () => {
		const raw = {
			doctype: 'Order',
			domain: 'sales',
			fields: {},
			actions: {
				approve: {
					args: {},
					states: { status: ['submitted', 'pending'] }
				}
			}
		};
		const parsed = parseDoctypeDef(raw);
		expect(parsed.actions[0].states).toEqual({ status: ['submitted', 'pending'] });
		const out = serializeDoctypeDef(parsed, raw);
		expect(out.actions).toEqual(raw.actions);
	});

	describe('actionStateAllowed', () => {
		it('is true without a gate', () => {
			expect(actionStateAllowed({}, { status: 'closed' })).toBe(true);
		});

		it('requires every gated field to carry a listed string value', () => {
			const act = { states: { status: ['submitted', 'pending'] } };
			expect(actionStateAllowed(act, { status: 'submitted' })).toBe(true);
			expect(actionStateAllowed(act, { status: 'closed' })).toBe(false);
			expect(actionStateAllowed(act, {})).toBe(false);
			expect(actionStateAllowed(act, { status: 3 })).toBe(false);
		});
	});

	it('preserves keys the editor does not surface (search, display_name, scopes, migrations)', () => {
		const raw = {
			doctype: 'Person',
			domain: 'identity',
			fields: { full_name: { type: 'string' } },
			search: '{{ full_name }} {{ email }}',
			display_name: '$full_name',
			scopes: { owned_by_self: { where: { owner_id: '$self' } } },
			migrations: { '1': 'migrate_from_1' }
		};
		const parsed = parseDoctypeDef(raw);
		// `search` and `migrations` are surfaced on the typed DoctypeDef; the
		// other preserved keys are not.
		expect(parsed.search).toEqual('{{ full_name }} {{ email }}');
		expect(parsed.migrations).toEqual(raw.migrations);
		expect(parsed).not.toHaveProperty('display_name');
		const out = serializeDoctypeDef(parsed, raw);
		expect(out.search).toEqual('{{ full_name }} {{ email }}');
		expect(out.display_name).toBe('$full_name');
		expect(out.scopes).toEqual(raw.scopes);
		expect(out.migrations).toEqual(raw.migrations);
	});

	it('omits `color` when the editor cleared it (empty string)', () => {
		const raw = { doctype: 'T', domain: 'd', fields: {}, color: '#aabbcc' };
		const parsed = parseDoctypeDef(raw);
		// Simulate the user clearing the color input — the editor coalesces
		// `undefined` to '' on the working copy so the bind target is defined.
		parsed.color = '';
		const out = serializeDoctypeDef(parsed, raw);
		expect(out.color).toBeUndefined();
	});

	it('round-trips `icon` and clears it when the editor empties it', () => {
		const raw = { doctype: 'T', domain: 'd', fields: {}, icon: 'building-2' };
		const parsed = parseDoctypeDef(raw);
		expect(parsed.icon).toBe('building-2');
		expect(serializeDoctypeDef(parsed, raw).icon).toBe('building-2');

		// Clearing the icon ('' on the working copy) must erase it from the body.
		parsed.icon = '';
		const out = serializeDoctypeDef(parsed, raw);
		expect(out.icon).toBeUndefined();
	});

	it('round-trips `plural_label` and clears it when the editor empties it', () => {
		const raw = { doctype: 'T', domain: 'd', fields: {}, plural_label: 'contacts' };
		const parsed = parseDoctypeDef(raw);
		expect(parsed.plural_label).toBe('contacts');
		expect(serializeDoctypeDef(parsed, raw).plural_label).toBe('contacts');

		// Clearing the plural ('' on the working copy) must erase it from the
		// body so the backend falls back to the naive pluraliser.
		parsed.plural_label = '';
		const out = serializeDoctypeDef(parsed, raw);
		expect(out.plural_label).toBeUndefined();
	});

	it('joins nested `properties` and `items` back to the dictionary/object shape', () => {
		const raw = {
			doctype: 'Doc',
			domain: 'd',
			fields: {
				addr: {
					type: 'object',
					properties: {
						street: { type: 'string' },
						zip: { type: 'string', pattern: '^\\d{5}$' }
					}
				},
				tags: {
					type: 'array',
					items: { type: 'string' }
				}
			}
		};
		const parsed = parseDoctypeDef(raw);
		const out = serializeDoctypeDef(parsed, raw);
		expect(out.fields).toEqual(raw.fields);
	});

	it('round-trips a replicated field config (B-130)', () => {
		const raw = {
			doctype: 'Employee',
			domain: 'hr',
			fields: {
				dept_name: {
					type: 'string',
					replicate: { via: 'department', field: 'name' }
				}
			}
		};
		const parsed = parseDoctypeDef(raw);
		expect(parsed.fields[0].replicate).toEqual({ via: 'department', field: 'name' });
		// The save path must not drop the replicate config.
		const out = serializeDoctypeDef(parsed, raw);
		expect(out.fields).toEqual(raw.fields);
	});

	it('parses the dictionary entry-value definition from `values:` (B-105)', () => {
		const raw = {
			doctype: 'Doc',
			domain: 'd',
			fields: {
				counters: {
					type: 'dictionary',
					values: { type: 'integer' }
				},
				freeform: { type: 'dictionary' }
			}
		};
		const parsed = parseDoctypeDef(raw);
		expect(parsed.fields[0].dictionaryValue).toMatchObject({ key: '(value)', type: 'integer' });
		// A dictionary without `values:` carries no entry schema.
		expect(parsed.fields[1].dictionaryValue).toBeUndefined();
		// The save path serializes the parsed schema back under `values:`, so
		// the doctype editor cannot erase a declared entry schema.
		const out = serializeDoctypeDef(parsed, raw);
		expect(out.fields).toEqual(raw.fields);
	});
});

describe('serializeDoctypeDef — migrations (B-303)', () => {
	it('round-trips a declared migration map from the working copy', () => {
		const raw = {
			doctype: 'Person',
			domain: 'identity',
			fields: {},
			schema_version: 2,
			migrations: { '1': 'migrate_from_1' }
		};
		const parsed = parseDoctypeDef(raw);
		const out = serializeDoctypeDef(parsed, raw);
		expect(out.migrations).toEqual({ '1': 'migrate_from_1' });
	});

	it('carries a map the editor authored, even when the raw record had none', () => {
		const raw = { doctype: 'Person', domain: 'identity', fields: {} };
		const parsed = parseDoctypeDef(raw);
		parsed.migrations = { '1': 'migrate_from_1', '2': 'migrate_from_2' };
		const out = serializeDoctypeDef(parsed, raw);
		expect(out.migrations).toEqual({ '1': 'migrate_from_1', '2': 'migrate_from_2' });
	});

	it('erases stale migrations carried in preserved when the working copy cleared them', () => {
		const raw = {
			doctype: 'Person',
			domain: 'identity',
			fields: {},
			migrations: { '1': 'migrate_from_1' }
		};
		const parsed = parseDoctypeDef(raw);
		// The editor coalesces an absent map to {} so the section can mutate it.
		parsed.migrations = {};
		const out = serializeDoctypeDef(parsed, raw);
		expect(out).not.toHaveProperty('migrations');
	});

	it('ignores a malformed or empty migrations map at parse time', () => {
		const malformed = parseDoctypeDef({
			doctype: 'T',
			domain: 'd',
			fields: {},
			migrations: 'nope'
		});
		expect(malformed.migrations).toBeUndefined();
		const nonString = parseDoctypeDef({
			doctype: 'T',
			domain: 'd',
			fields: {},
			migrations: { '1': 42 }
		});
		expect(nonString.migrations).toBeUndefined();
	});
});

describe('serializeDoctypeDef — sidecars', () => {
	it('round-trips sidecar, sidecars (order + label variants) and surface', () => {
		const raw = {
			doctype: 'Deal',
			domain: 'crm',
			fields: {},
			sidecar: true,
			surface: 'deal',
			sidecars: {
				notes: { doctype: 'core.Note', column: 'target', order: 2, label: 'Notes' },
				comments: { doctype: 'core.Comment', column: 'target' }
			}
		};
		const parsed = parseDoctypeDef(raw);
		expect(parsed.sidecar).toBe(true);
		expect(parsed.surface).toBe('deal');
		// Tab order key is {order ?? 0, key}: comments (0) before notes (2).
		expect(parsed.sidecars?.map((s) => s.key)).toEqual(['comments', 'notes']);
		const out = serializeDoctypeDef(parsed, raw);
		expect(out.sidecar).toBe(true);
		expect(out.surface).toBe('deal');
		expect(out.sidecars).toEqual(raw.sidecars);
	});

	it('sorts sidecars by {order ?? 0, key} — numeric order, then key tiebreak', () => {
		const raw = {
			doctype: 'Deal',
			domain: 'crm',
			fields: {},
			sidecars: {
				zebra: { doctype: 'core.Z', column: 'target' },
				alpha: { doctype: 'core.A', column: 'target', order: 0 },
				mid: { doctype: 'core.M', column: 'target', order: 1 }
			}
		};
		const parsed = parseDoctypeDef(raw);
		expect(parsed.sidecars?.map((s) => s.key)).toEqual(['alpha', 'zebra', 'mid']);
	});

	it('omits order when it is the default 0', () => {
		const raw = {
			doctype: 'Deal',
			domain: 'crm',
			fields: {},
			sidecars: { comments: { doctype: 'core.Comment', column: 'target', order: 0 } }
		};
		const parsed = parseDoctypeDef(raw);
		const out = serializeDoctypeDef(parsed, raw);
		expect(out.sidecars).toEqual({ comments: { doctype: 'core.Comment', column: 'target' } });
	});

	it('emits no sidecar/sidecars/surface keys when the definition has none', () => {
		const raw = { doctype: 'Task', domain: 'crm', fields: {} };
		const parsed = parseDoctypeDef(raw);
		const out = serializeDoctypeDef(parsed, raw);
		expect(out).not.toHaveProperty('sidecar');
		expect(out).not.toHaveProperty('sidecars');
		expect(out).not.toHaveProperty('surface');
	});

	it('erases stale sidecar values carried in preserved when the working copy cleared them', () => {
		const raw = {
			doctype: 'Deal',
			domain: 'crm',
			fields: {},
			sidecar: true,
			surface: 'deal',
			sidecars: { comments: { doctype: 'core.Comment', column: 'target' } }
		};
		const parsed = parseDoctypeDef(raw);
		// Simulate the editor clearing every sidecar knob on the working copy.
		parsed.sidecar = false;
		parsed.sidecars = [];
		parsed.surface = undefined;
		const out = serializeDoctypeDef(parsed, raw);
		expect(out).not.toHaveProperty('sidecar');
		expect(out).not.toHaveProperty('sidecars');
		expect(out).not.toHaveProperty('surface');
	});
});

describe('serializeDoctypeDef — independent of preserved record', () => {
	it('builds a valid body when no raw record is supplied (new doctype case)', () => {
		const def: DoctypeDef = {
			doctype: 'WorkOrder',
			domain: 'production',
			schema_version: 1,
			fields: [{ key: 'subject', type: 'string', required: true }],
			children: [],
			actions: []
		};
		const out = serializeDoctypeDef(def);
		expect(out).toEqual({
			doctype: 'WorkOrder',
			domain: 'production',
			schema_version: 1,
			fields: { subject: { type: 'string', required: true } },
			children: {},
			actions: {}
		});
	});
});
