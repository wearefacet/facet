// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it } from 'vitest';
import {
	avatarTintOf,
	deletedTitle,
	displayLabel,
	initialsFromLabel,
	photoUrlOf,
	sourceLabelOf,
	statusBadgeLabel,
	statusBadgeTint,
	statusFieldOf,
	statusValueOf,
	subLabel
} from './documentIdentity.js';
import type { QvDocument } from './documentIdentity.js';
import type { DoctypeDef, FieldDef } from '$lib/doctype/types.js';

function doc(
	data: Record<string, unknown> = {},
	displayName: string | null = null,
	id = 'doc-1'
): QvDocument {
	return {
		data,
		meta: {
			id,
			mid: 'mid-1',
			domain: 'crm',
			doc_type: 'Contact',
			version: 3,
			schema_version: 1,
			display_name: displayName,
			created_at: '2026-01-01T00:00:00Z',
			updated_at: '2026-01-02T00:00:00Z'
		}
	};
}

const DEF: DoctypeDef = {
	domain: 'crm',
	doctype: 'Contact',
	fields: [
		{ key: 'name', type: 'string' },
		{ key: 'status', type: 'enum', values: [{ key: 'open', color: '#0a0' }, { key: 'closed' }] }
	],
	children: [],
	actions: []
};

const STATUS_FIELD: FieldDef = DEF.fields[1];

describe('displayLabel', () => {
	it('prefers meta.display_name over content fields', () => {
		expect(displayLabel(doc({ title: 'T', name: 'N' }, 'Display Name'))).toBe('Display Name');
	});

	it('falls back to title, then name, then label', () => {
		expect(displayLabel(doc({ title: 'T', name: 'N', label: 'L' }))).toBe('T');
		expect(displayLabel(doc({ name: 'N', label: 'L' }))).toBe('N');
		expect(displayLabel(doc({ label: 'L' }))).toBe('L');
	});

	it('skips empty-string label fields', () => {
		expect(displayLabel(doc({ title: '', name: '', label: 'L' }))).toBe('L');
	});

	it('treats an empty display_name as absent', () => {
		expect(displayLabel(doc({ name: 'N' }, ''))).toBe('N');
	});

	it('falls back to the raw id', () => {
		expect(displayLabel(doc({}, null, 'doc-9'))).toBe('doc-9');
	});

	it('returns an empty string without a document', () => {
		expect(displayLabel(null)).toBe('');
	});
});

describe('subLabel', () => {
	it('probes the subtitle fields in order', () => {
		expect(subLabel(doc({ headline: 'H', summary: 'S' }))).toBe('H');
		expect(subLabel(doc({ summary: 'S' }))).toBe('S');
	});

	it('trims the value', () => {
		expect(subLabel(doc({ headline: '  Hello there  ' }))).toBe('Hello there');
	});

	it('skips whitespace-only values', () => {
		expect(subLabel(doc({ headline: '   ', summary: 'S' }))).toBe('S');
	});

	it('returns an empty string when no field matches', () => {
		expect(subLabel(doc({ name: 'N' }))).toBe('');
		expect(subLabel(null)).toBe('');
	});
});

describe('statusFieldOf', () => {
	it('returns the status field when it is an enum', () => {
		expect(statusFieldOf(DEF)).toBe(STATUS_FIELD);
	});

	it('returns null for a non-enum status field', () => {
		const def: DoctypeDef = {
			domain: 'crm',
			doctype: 'Contact',
			fields: [{ key: 'status', type: 'string' }],
			children: [],
			actions: []
		};
		expect(statusFieldOf(def)).toBeNull();
	});

	it('returns null when the doctype has no status field', () => {
		const def: DoctypeDef = {
			domain: 'crm',
			doctype: 'Contact',
			fields: [],
			children: [],
			actions: []
		};
		expect(statusFieldOf(def)).toBeNull();
	});
});

describe('statusValueOf', () => {
	it('returns the status content value', () => {
		expect(statusValueOf(doc({ status: 'open' }), STATUS_FIELD)).toBe('open');
	});

	it('returns null without a field or without a document', () => {
		expect(statusValueOf(doc({ status: 'open' }), null)).toBeNull();
		expect(statusValueOf(null, STATUS_FIELD)).toBeNull();
	});

	it('returns null for missing, empty, and non-string values', () => {
		expect(statusValueOf(doc({}), STATUS_FIELD)).toBeNull();
		expect(statusValueOf(doc({ status: '' }), STATUS_FIELD)).toBeNull();
		expect(statusValueOf(doc({ status: 42 }), STATUS_FIELD)).toBeNull();
		expect(statusValueOf(doc({ status: null }), STATUS_FIELD)).toBeNull();
	});
});

describe('statusBadgeLabel', () => {
	it('humanizes the value', () => {
		expect(statusBadgeLabel('in_progress')).toBe('In Progress');
	});

	it('returns null without a value', () => {
		expect(statusBadgeLabel(null)).toBeNull();
	});
});

describe('statusBadgeTint', () => {
	it('returns the color of the matching enum entry', () => {
		expect(statusBadgeTint(STATUS_FIELD, 'open')).toBe('#0a0');
	});

	it('returns undefined when the entry has no color', () => {
		expect(statusBadgeTint(STATUS_FIELD, 'closed')).toBeUndefined();
	});

	it('returns undefined when the value has no entry', () => {
		expect(statusBadgeTint(STATUS_FIELD, 'unknown')).toBeUndefined();
	});

	it('returns undefined without a field or without a value', () => {
		expect(statusBadgeTint(null, 'open')).toBeUndefined();
		expect(statusBadgeTint(STATUS_FIELD, null)).toBeUndefined();
	});
});

describe('photoUrlOf', () => {
	it('prefers photo, then avatar_url, then icon', () => {
		expect(photoUrlOf(doc({ photo: 'p', avatar_url: 'a', icon: 'i' }))).toBe('p');
		expect(photoUrlOf(doc({ avatar_url: 'a', icon: 'i' }))).toBe('a');
		expect(photoUrlOf(doc({ icon: 'i' }))).toBe('i');
	});

	it('skips empty strings', () => {
		expect(photoUrlOf(doc({ photo: '', icon: 'i' }))).toBe('i');
	});

	it('returns null when no field carries a non-empty string', () => {
		expect(photoUrlOf(doc({ icon: 42 }))).toBeNull();
		expect(photoUrlOf(doc({}))).toBeNull();
		expect(photoUrlOf(null)).toBeNull();
	});
});

describe('initialsFromLabel', () => {
	it('takes the first letter of the first two words, uppercased', () => {
		expect(initialsFromLabel('Ada Lovelace')).toBe('AL');
		expect(initialsFromLabel('a b c')).toBe('AB');
	});

	it('takes one letter for a single word', () => {
		expect(initialsFromLabel('madonna')).toBe('M');
	});

	it('collapses whitespace', () => {
		expect(initialsFromLabel('  Ada   Lovelace ')).toBe('AL');
	});

	it("returns '#' for an empty label", () => {
		expect(initialsFromLabel('')).toBe('#');
		expect(initialsFromLabel('   ')).toBe('#');
	});
});

describe('sourceLabelOf', () => {
	it('humanizes a non-empty string source', () => {
		expect(sourceLabelOf(doc({ source: 'email_list' }))).toBe('Email List');
	});

	it('returns null for absent, empty, and non-string values', () => {
		expect(sourceLabelOf(doc({}))).toBeNull();
		expect(sourceLabelOf(doc({ source: '' }))).toBeNull();
		expect(sourceLabelOf(doc({ source: 5 }))).toBeNull();
		expect(sourceLabelOf(doc({ source: null }))).toBeNull();
		expect(sourceLabelOf(null)).toBeNull();
	});
});

describe('avatarTintOf', () => {
	it('uses the doctype accent color', () => {
		expect(avatarTintOf({ ...DEF, color: '#123456' })).toBe('#123456');
	});

	it('falls back to the brand accent', () => {
		expect(avatarTintOf(DEF)).toBe('var(--accent)');
	});
});

describe('deletedTitle', () => {
	it('uses the surviving display name', () => {
		expect(
			deletedTitle({ def: DEF, docId: 'doc-1', displayName: 'Old Row', deletedAt: null })
		).toBe('Old Row');
	});

	it('falls back to the qualified doctype name', () => {
		expect(deletedTitle({ def: DEF, docId: 'doc-1', displayName: null, deletedAt: null })).toBe(
			'crm.Contact'
		);
	});
});
