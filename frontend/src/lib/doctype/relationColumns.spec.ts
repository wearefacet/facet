// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import type { DocumentResponse } from '$lib/datasource/types.js';
import type { RelationNode } from '$lib/template-types.js';
import { parseDoctypeDef } from './types.js';
import {
	REF_KEY_SEP,
	columnRefTargets,
	parseColumnKey,
	parseReferenceId,
	refKey,
	resolveColumnCell,
	rowCapsuleReference,
	rowDocument,
	rowToDraft,
	seedEmptyDraft,
	splitRefKey,
	tableNeedsHydration,
	toggleTarget
} from './relationColumns.js';

/**
 * Resolution matrix for table-view relation columns: local column, one-hop
 * traversal, missing intermediate document, unsupported multi-hop (blank),
 * and the terminal `FieldDef` deciding the cell type.
 */

const membershipDef = parseDoctypeDef({
	doctype: 'CompanyMembership',
	domain: 'crm',
	schema_version: 1,
	fields: {
		role: {
			type: 'enum',
			values: [
				{ key: 'primary', label: 'Primary' },
				{ key: 'secondary', label: 'Secondary' }
			]
		},
		contact: { type: 'reference', doctype: 'crm.Contact' },
		note: { type: 'string' }
	}
});

const contactDef = parseDoctypeDef({
	doctype: 'Contact',
	domain: 'crm',
	schema_version: 1,
	fields: {
		full_name: { type: 'data' },
		email: { type: 'string' },
		phone: { type: 'phone' }
	}
});

const contactDoc: DocumentResponse = {
	data: { full_name: 'Alice Johnson', email: 'alice@acme.com', phone: '+1-555-0101' },
	meta: {
		id: 'crm.Contact.1',
		mid: 'crm.Contact.1',
		domain: 'crm',
		doc_type: 'Contact',
		version: 1,
		schema_version: 1,
		created_at: '',
		updated_at: ''
	}
};

function row(data: Record<string, unknown>) {
	return { meta: { id: 'crm.CompanyMembership.1', display_name: null }, data };
}

function cell(
	rowArg: ReturnType<typeof row>,
	key: string,
	docs: Map<string, DocumentResponse>,
	defs: Map<string, ReturnType<typeof parseDoctypeDef>>,
	relationDef = membershipDef
) {
	return resolveColumnCell(rowArg, key, docs, defs, relationDef);
}

describe('column key parsing', () => {
	it('splits dotted keys', () => {
		expect(parseColumnKey('contact.email')).toEqual(['contact', 'email']);
		expect(parseColumnKey('role')).toEqual(['role']);
	});

	it('round-trips ref keys through the control-char separator', () => {
		const key = refKey('crm.Contact', 'crm.Contact.1');
		expect(key).toBe(`crm.Contact${REF_KEY_SEP}crm.Contact.1`);
		expect(splitRefKey(key)).toEqual({ qualified: 'crm.Contact', id: 'crm.Contact.1' });
		expect(splitRefKey('crm.Contact.1')).toBeNull();
		expect(splitRefKey('crm.Contact\u0001')).toBeNull();
	});
});

describe('resolveColumnCell — local columns', () => {
	it('reads the row data and types from the relation def', () => {
		const r = row({ role: 'primary', note: 'hi' });
		const c = cell(r, 'role', new Map(), new Map());
		expect(c.value).toBe('primary');
		expect(c.fieldDef?.key).toBe('role');
		expect(c.fieldType).toBe('enum');
	});

	it('falls back to a string type for an unknown local field', () => {
		const c = cell(row({ mystery: 1 }), 'mystery', new Map(), new Map());
		expect(c.value).toBe(1);
		expect(c.fieldDef).toBeNull();
		expect(c.fieldType).toBe('string');
	});
});

describe('resolveColumnCell — one-hop traversal', () => {
	const docs = new Map([[refKey('crm.Contact', 'crm.Contact.1'), contactDoc]]);
	const defs = new Map([['crm.Contact', contactDef]]);

	it('resolves the referenced document and reads the leaf value', () => {
		const c = cell(row({ contact: 'crm.Contact.1' }), 'contact.email', docs, defs);
		expect(c.value).toBe('alice@acme.com');
		expect(c.fieldDef?.key).toBe('email');
		expect(c.fieldType).toBe('string');
	});

	it('the terminal FieldDef decides the cell type (phone)', () => {
		const c = cell(row({ contact: 'crm.Contact.1' }), 'contact.phone', docs, defs);
		expect(c.value).toBe('+1-555-0101');
		expect(c.fieldType).toBe('phone');
	});

	it('renders a blank cell when the intermediate document is missing', () => {
		const c = cell(row({ contact: 'crm.Contact.1' }), 'contact.email', new Map(), defs);
		expect(c).toEqual({ value: undefined, fieldDef: null, fieldType: null });
	});

	it('renders a blank cell when the row has no reference id', () => {
		const c = cell(row({}), 'contact.email', docs, defs);
		expect(c).toEqual({ value: undefined, fieldDef: null, fieldType: null });
	});

	it('renders a blank cell when the first segment is not a reference field', () => {
		const c = cell(row({ note: 'x' }), 'note.email', docs, defs);
		expect(c).toEqual({ value: undefined, fieldDef: null, fieldType: null });
	});

	it('renders a blank cell when the leaf field is unknown on the target def', () => {
		const c = cell(row({ contact: 'crm.Contact.1' }), 'contact.mystery', docs, defs);
		expect(c.value).toBeUndefined();
		expect(c.fieldDef).toBeNull();
		expect(c.fieldType).toBe('string');
	});
});

describe('resolveColumnCell — unsupported multi-hop', () => {
	const docs = new Map([[refKey('crm.Contact', 'crm.Contact.1'), contactDoc]]);
	const defs = new Map([['crm.Contact', contactDef]]);

	it('renders blank when the second segment is not a reference on the target doctype', () => {
		// contact.company.name: `company` is not a reference on crm.Contact, so
		// the walk fails — the cell renders the em-dash blank in DvtValue.
		const c = cell(row({ contact: 'crm.Contact.1' }), 'contact.company.name', docs, defs);
		expect(c).toEqual({ value: undefined, fieldDef: null, fieldType: null });
	});

	it('renders blank when a deeper hop was never hydrated (no cached doc)', () => {
		// team.lead.name — `team` hydrates, but the second-hop document is never
		// fetched by the hydration pass, so the walk stops blank.
		const teamDef = parseDoctypeDef({
			doctype: 'Team',
			domain: 'crm',
			schema_version: 1,
			fields: {
				lead: { type: 'reference', doctype: 'crm.Contact' },
				name: { type: 'string' }
			}
		});
		const membershipWithTeam = parseDoctypeDef({
			doctype: 'CompanyMembership',
			domain: 'crm',
			schema_version: 1,
			fields: { team: { type: 'reference', doctype: 'crm.Team' } }
		});
		const teamDoc: DocumentResponse = {
			data: { lead: 'crm.Contact.1', name: 'Platform' },
			meta: { ...contactDoc.meta, id: 'crm.Team.1', doc_type: 'Team' }
		};
		const teamDocs = new Map([[refKey('crm.Team', 'crm.Team.1'), teamDoc]]);
		const teamDefs = new Map([
			['crm.Team', teamDef],
			['crm.Contact', contactDef]
		]);
		const c = cell(
			row({ team: 'crm.Team.1' }),
			'team.lead.name',
			teamDocs,
			teamDefs,
			membershipWithTeam
		);
		// The walk hydrated `team`, but `crm.Contact.1` is not in the docs map
		// (the hydration pass collects first-hop keys only) — blank.
		expect(c).toEqual({ value: undefined, fieldDef: null, fieldType: null });
	});

	it('columnRefTargets collects only the first hop of each column', () => {
		const template = {
			columns: [
				{ key: 'contact.email', label: 'Email' },
				{ key: 'role', label: 'Role' }
			]
		} as Pick<RelationNode, 'columns'>;
		expect(columnRefTargets(template, membershipDef)).toEqual(['crm.Contact']);
	});

	it('columnRefTargets returns empty without a relation def', () => {
		expect(
			columnRefTargets({ columns: [{ key: 'contact.email', label: 'Email' }] }, undefined)
		).toEqual([]);
	});

	it('tableNeedsHydration is true only for table mode with a dotted column', () => {
		const template = {
			columns: [
				{ key: 'contact.email', label: 'Email' },
				{ key: 'role', label: 'Role' }
			]
		} as Pick<RelationNode, 'columns'>;
		expect(tableNeedsHydration(template, 'table')).toBe(true);
		expect(tableNeedsHydration({ columns: [{ key: 'role', label: 'Role' }] }, 'table')).toBe(false);
		expect(tableNeedsHydration(template, 'capsule')).toBe(false);
	});
});

describe('toggleTarget — inline boolean columns', () => {
	const toggleDef = parseDoctypeDef({
		doctype: 'CompanyMembership',
		domain: 'crm',
		schema_version: 1,
		fields: {
			primary: { type: 'boolean' },
			locked: { type: 'boolean', read_only: true },
			role: { type: 'enum', values: [{ key: 'primary', label: 'Primary' }] },
			contact: { type: 'reference', doctype: 'crm.Contact' }
		}
	});

	it('resolves an editable local boolean column to its FieldDef', () => {
		const fd = toggleTarget({ key: 'primary', label: 'Primary', editable: true }, toggleDef);
		expect(fd?.key).toBe('primary');
		expect(fd?.type).toBe('boolean');
	});

	it('ignores the flag when absent', () => {
		expect(toggleTarget({ key: 'primary', label: 'Primary' }, toggleDef)).toBeNull();
	});

	it('refuses dotted keys — the leaf lives on a referenced document', () => {
		expect(
			toggleTarget({ key: 'contact.something', label: 'X', editable: true }, toggleDef)
		).toBeNull();
	});

	it('refuses non-boolean fields', () => {
		expect(toggleTarget({ key: 'role', label: 'Role', editable: true }, toggleDef)).toBeNull();
	});

	it('refuses read_only boolean fields', () => {
		expect(toggleTarget({ key: 'locked', label: 'Locked', editable: true }, toggleDef)).toBeNull();
	});

	it('returns null without a relation def', () => {
		expect(
			toggleTarget({ key: 'primary', label: 'Primary', editable: true }, undefined)
		).toBeNull();
	});
});

describe('parseReferenceId', () => {
	it('parses a qualified reference id', () => {
		expect(parseReferenceId('crm.Contact.1')).toEqual({
			domain: 'crm',
			doctype: 'Contact',
			id: 'crm.Contact.1'
		});
	});

	it('rejects bare and partial ids', () => {
		expect(parseReferenceId('plainid')).toBeNull();
		expect(parseReferenceId('crm.Contact')).toBeNull();
		expect(parseReferenceId('.Contact.x')).toBeNull();
		expect(parseReferenceId('')).toBeNull();
	});
});

describe('rowCapsuleReference', () => {
	it('returns the reference value when set', () => {
		expect(rowCapsuleReference(row({ contact: 'crm.Contact.1' }), 'contact')).toBe('crm.Contact.1');
		expect(rowCapsuleReference(row({ contact: '' }), 'contact')).toBeUndefined();
		expect(rowCapsuleReference(row({}), 'contact')).toBeUndefined();
		expect(rowCapsuleReference(row({ contact: 'crm.Contact.1' }), undefined)).toBeUndefined();
	});
});

describe('rowToDraft', () => {
	it('deep clones the row data so draft edits never leak into the rows cache', () => {
		const r = row({ role: 'primary', contact: 'crm.Contact.1' });
		const draft = rowToDraft(r);
		draft.values.role = 'secondary';
		expect(r.data.role).toBe('primary');
		expect(draft.id).toBe('crm.CompanyMembership.1');
	});
});

describe('seedEmptyDraft', () => {
	it('seeds typed placeholders and skips data/array/object fields', () => {
		const def = parseDoctypeDef({
			doctype: 'Widget',
			domain: 'test',
			schema_version: 1,
			fields: {
				name: { type: 'string' },
				active: { type: 'boolean' },
				count: { type: 'integer' },
				price: { type: 'money' },
				spent: { type: 'duration' },
				computed: { type: 'data' },
				tags: { type: 'array' },
				nested: { type: 'object' }
			}
		});
		expect(seedEmptyDraft(def)).toEqual({
			name: '',
			active: false,
			count: '',
			price: '',
			spent: 0
		});
	});

	it('honours declared field defaults over the type placeholder', () => {
		const def = parseDoctypeDef({
			doctype: 'Widget',
			domain: 'test',
			schema_version: 1,
			fields: {
				status: { type: 'enum', values: [{ key: 'draft', label: 'Draft' }], default: 'draft' },
				name: { type: 'string', default: 'Untitled' }
			}
		});
		expect(seedEmptyDraft(def)).toEqual({ status: 'draft', name: 'Untitled' });
	});

	it('returns an empty bag without a def', () => {
		expect(seedEmptyDraft(undefined)).toEqual({});
	});
});

describe('rowDocument', () => {
	it('builds a draft document meta from the relation identity', () => {
		const draft = { id: 'new:abc', values: { name: 'x' } };
		const doc = rowDocument(draft, { domain: 'hr', doctype: 'CandidateExperience' }, 3);
		expect(doc.data).toBe(draft.values);
		expect(doc.meta).toMatchObject({
			id: 'new:abc',
			mid: 'new:abc',
			domain: 'hr',
			doc_type: 'CandidateExperience',
			version: 0,
			schema_version: 3,
			display_name: null
		});
	});

	it('uses empty strings when the relation doctype is unparseable', () => {
		const doc = rowDocument({ id: 'd', values: {} }, null, 1);
		expect(doc.meta.domain).toBe('');
		expect(doc.meta.doc_type).toBe('');
		expect(doc.meta.schema_version).toBe(1);
	});
});
