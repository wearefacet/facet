// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import {
	auditFilterDoctype,
	AUDIT_ACTIONS,
	AUDIT_CAUSE_KINDS,
	AUDIT_CHANNELS
} from './auditFilters.js';
import { controlKindFor, filterableFields, operatorsFor } from '$lib/doctype/filters.js';
import type { FilterOperator } from '$lib/doctype/filters.js';
import { channelLabel } from './auditDiff.js';

// The filter grammar `Audit::List.build_column_filter` answers
// (`src/audit/list.cr`). Every `field__op` key the schema can emit must be in
// this set — an unsupported combination is answered 422 by the backend, which
// would turn a filter chip into an error. The attribution columns serve
// `eq` / `ne`; the doc pins (`domain`, `doc_type`, `doc_id`) serve `eq` only;
// `emitted_at` serves the range operators.
const backendKeys = new Set<string>(
	(['action', 'actioner_id', 'app', 'channel', 'kind', 'trace'] as const).flatMap((f) => [
		`${f}__eq`,
		`${f}__ne`
	])
);
for (const f of ['domain', 'doc_type', 'doc_id'] as const) backendKeys.add(`${f}__eq`);
for (const op of ['gte', 'lte'] as const) backendKeys.add(`emitted_at__${op}`);
const BACKEND_KEYS: ReadonlySet<string> = backendKeys;

const DEF = auditFilterDoctype({
	domains: [
		{ key: 'crm', label: 'crm' },
		{ key: 'iam', label: 'iam' }
	],
	doctypes: [{ key: 'crm.Company', label: 'crm.Company' }],
	apps: [{ key: '01APP', label: 'Ops Bot' }]
});

function field(key: string) {
	const f = DEF.fields.find((x) => x.key === key);
	if (!f) throw new Error(`missing field ${key}`);
	return f;
}

describe('auditFilterDoctype', () => {
	it('declares one field per filterable mutations column, in menu order', () => {
		expect(DEF.fields.map((f) => f.key)).toEqual([
			'action',
			'channel',
			'kind',
			'domain',
			'doc_type',
			'app',
			'actioner_id',
			'trace',
			'emitted_at'
		]);
	});

	it('emits only filter keys the audit backend answers', () => {
		for (const f of DEF.fields) {
			for (const op of operatorsFor(f)) {
				expect(BACKEND_KEYS.has(`${f.key}__${op}`), `${f.key}__${op}`).toBe(true);
			}
		}
	});

	it('declares no match operator, so the bar renders no search box', () => {
		for (const f of DEF.fields) {
			expect(operatorsFor(f)).not.toContain('match' satisfies FilterOperator);
		}
		expect(DEF.search).toBeUndefined();
	});

	it('makes every field filterable', () => {
		expect(filterableFields(DEF.fields)).toHaveLength(DEF.fields.length);
	});

	it('uses enum + reference + datetime + text control kinds', () => {
		expect(controlKindFor(field('action'), 'eq')).toBe('enum');
		expect(controlKindFor(field('channel'), 'ne')).toBe('enum');
		expect(controlKindFor(field('kind'), 'eq')).toBe('enum');
		expect(controlKindFor(field('domain'), 'eq')).toBe('enum');
		expect(controlKindFor(field('app'), 'eq')).toBe('enum');
		expect(controlKindFor(field('actioner_id'), 'eq')).toBe('reference');
		expect(controlKindFor(field('actioner_id'), 'ne')).toBe('reference');
		expect(controlKindFor(field('trace'), 'eq')).toBe('text');
		expect(controlKindFor(field('emitted_at'), 'gte')).toBe('datetime');
		expect(controlKindFor(field('emitted_at'), 'lte')).toBe('datetime');
	});

	it('targets the actor reference combobox at iam.Account', () => {
		expect(field('actioner_id').doctype).toBe('iam.Account');
	});

	it('offers the full action / channel / cause-kind vocabularies', () => {
		expect(field('action').values?.map((v) => v.key)).toEqual([...AUDIT_ACTIONS]);
		expect(field('channel').values?.map((v) => v.key)).toEqual([...AUDIT_CHANNELS]);
		expect(field('kind').values?.map((v) => v.key)).toEqual([...AUDIT_CAUSE_KINDS]);
		// 13 members of `Mutation::CauseKind` — a new backend member must be
		// added here or it stays unfilterable.
		expect(AUDIT_CAUSE_KINDS).toHaveLength(13);
	});

	it('labels the session channel `facet` and keeps other channels verbatim', () => {
		const values = field('channel').values ?? [];
		expect(values.find((v) => v.key === 'session')?.label).toBe(channelLabel('session'));
		expect(values.find((v) => v.key === 'session')?.label).toBe('facet');
		expect(values.find((v) => v.key === 'api_key')?.label).toBe('api_key');
	});

	it('pins domain and doc_type to eq — the backend serves no ne on the doc pins', () => {
		expect(operatorsFor(field('domain'))).toEqual(['eq']);
		expect(operatorsFor(field('doc_type'))).toEqual(['eq']);
	});

	it('carries the injected dynamic enum values', () => {
		expect(field('domain').values?.map((v) => v.key)).toEqual(['crm', 'iam']);
		// The doctype picker carries qualified keys — one pick filters domain
		// and doctype at the same time (the backend splits the value).
		expect(field('doc_type').values?.map((v) => v.key)).toEqual(['crm.Company']);
		expect(field('doc_type').values?.map((v) => v.label)).toEqual(['crm.Company']);
		expect(field('app').values?.map((v) => v.label)).toEqual(['Ops Bot']);
	});

	it('defaults the dynamic enums to empty (registry/app loads pending)', () => {
		const bare = auditFilterDoctype();
		for (const key of ['domain', 'doc_type', 'app']) {
			expect(bare.fields.find((f) => f.key === key)?.values).toEqual([]);
		}
	});
});
