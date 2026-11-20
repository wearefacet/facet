// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { previewDocument, defaultViewTemplate, VIEW_KINDS } from './previewDocument.js';
import { parseDoctypeDef, type DoctypeDef } from './types.js';

function defOf(raw: Record<string, unknown>): DoctypeDef {
	return parseDoctypeDef(raw);
}

describe('VIEW_KINDS', () => {
	it('lists the five core view kinds', () => {
		expect(VIEW_KINDS).toEqual(['view', 'form', 'inline', 'card', 'quickView']);
	});
});

describe('previewDocument', () => {
	it('produces a { data, meta } DocumentResponse with stable meta', () => {
		const def = defOf({ doctype: 'Employee', domain: 'hr', fields: {} });
		const doc = previewDocument(def);
		expect(doc.meta.id).toBe('hr.Employee.sample');
		expect(doc.meta.domain).toBe('hr');
		expect(doc.meta.doc_type).toBe('Employee');
		expect(doc.meta.version).toBe(1);
		expect(doc.meta.display_name).toBe('Sample Employee');
	});

	it('generates a string sample from field title when present', () => {
		const def = defOf({
			doctype: 'Employee',
			domain: 'hr',
			fields: { full_name: { type: 'string', title: 'Full Name' } }
		});
		const doc = previewDocument(def);
		expect(doc.data).toEqual({ full_name: 'Sample Full Name' });
	});

	it('honors field default over sample generation', () => {
		const def = defOf({
			doctype: 'Task',
			domain: 'crm',
			fields: { status: { type: 'string', default: 'open' } }
		});
		expect(previewDocument(def).data).toEqual({ status: 'open' });
	});

	it('renders enum as the first declared value', () => {
		const def = defOf({
			doctype: 'Task',
			domain: 'crm',
			fields: { stage: { type: 'enum', values: [{ key: 'todo' }, { key: 'done' }] } }
		});
		expect(previewDocument(def).data).toEqual({ stage: 'todo' });
	});

	it('renders money as { value, currency } honoring field currency', () => {
		const def = defOf({
			doctype: 'Deal',
			domain: 'crm',
			fields: { amount: { type: 'money', currency: 'USD' } }
		});
		expect(previewDocument(def).data).toEqual({ amount: { value: '4200', currency: 'USD' } });
	});

	it('renders reference as a synthetic qualified id without hydration', () => {
		const def = defOf({
			doctype: 'Deal',
			domain: 'crm',
			fields: { owner: { type: 'reference', doctype: 'iam.Account' } }
		});
		expect(previewDocument(def).data).toEqual({ owner: 'iam.Account.sample' });
	});

	it('picks the midpoint when min and max are set on an integer', () => {
		const def = defOf({
			doctype: 'Product',
			domain: 'inv',
			fields: { qty: { type: 'integer', min: 0, max: 100 } }
		});
		expect(previewDocument(def).data).toEqual({ qty: 50 });
	});

	it('skips computed (data) and child fields from the mock payload', () => {
		const def = defOf({
			doctype: 'Deal',
			domain: 'crm',
			fields: {
				name: { type: 'string' },
				derived_score: { type: 'data', compute: 'compute_score' },
				line_items: { type: 'child', doctype: 'crm.LineItem', collection: true }
			}
		});
		expect(previewDocument(def).data).toEqual({ name: 'Sample Name' });
	});

	it('recurses into object sub-fields', () => {
		const def = defOf({
			doctype: 'Employee',
			domain: 'hr',
			fields: {
				address: {
					type: 'object',
					properties: { city: { type: 'string', title: 'City' } }
				}
			}
		});
		expect(previewDocument(def).data).toEqual({ address: { city: 'Sample City' } });
	});

	it('applies user overrides on top of generated values', () => {
		const def = defOf({
			doctype: 'Employee',
			domain: 'hr',
			fields: { name: { type: 'string' } }
		});
		expect(previewDocument(def, { name: 'Jane Doe' }).data).toEqual({ name: 'Jane Doe' });
	});

	it('is deterministic — calling twice yields the same document', () => {
		const def = defOf({
			doctype: 'Employee',
			domain: 'hr',
			fields: {
				name: { type: 'string' },
				hired_at: { type: 'datetime' },
				status: { type: 'enum', values: [{ key: 'active' }] }
			}
		});
		expect(previewDocument(def)).toEqual(previewDocument(def));
	});
});

describe('defaultViewTemplate', () => {
	it('emits a col with one field node per displayable field', () => {
		// parseFieldEntries sorts alphabetically by key — the template must
		// follow the same order so the preview matches what users see in the
		// editor (which also lists sorted fields).
		const def = defOf({
			doctype: 'Task',
			domain: 'crm',
			fields: {
				title: { type: 'string', title: 'Title' },
				status: { type: 'enum', values: [{ key: 'open' }] }
			}
		});
		const tpl = defaultViewTemplate(def);
		expect(tpl).toEqual({
			type: 'col',
			children: [
				{ type: 'field', label: 'Status', value: '$status' },
				{ type: 'field', label: 'Title', value: '$title' }
			]
		});
	});

	it('omits child and data fields from the default template', () => {
		const def = defOf({
			doctype: 'Task',
			domain: 'crm',
			fields: {
				title: { type: 'string' },
				derived: { type: 'data', compute: 'fn' },
				line_items: { type: 'child', doctype: 'crm.LineItem' }
			}
		});
		const tpl = defaultViewTemplate(def);
		if (tpl.type !== 'col') throw new Error('expected col root');
		expect(tpl.children).toHaveLength(1);
	});

	it('falls back to a label node when the doctype has no displayable fields', () => {
		const def = defOf({ doctype: 'Empty', domain: 'crm', fields: {} });
		const tpl = defaultViewTemplate(def);
		expect(tpl.type).toBe('label');
	});
});
