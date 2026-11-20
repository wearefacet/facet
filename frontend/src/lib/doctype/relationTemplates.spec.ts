// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import type { DataDriver } from '$lib/datasource/driver.js';
import type { TemplateNode } from '$lib/template-types.js';
import { loadRelationTemplates } from './relationTemplates.js';
import { parseDoctypeDef } from './types.js';

/**
 * Loader semantics: def resolution (native mock map vs `core.DocType`
 * registry), form-vs-inline kind selection, the `quickView` fallback, and
 * the load-once cache contract (already-cached pieces are not re-fetched).
 */

interface ViewChild {
	data: { kind: string; template?: TemplateNode };
	meta: { id: string };
}

const formTemplate: TemplateNode = { type: 'field', value: '$company' };
const inlineTemplate: TemplateNode = { type: 'label', value: '$company' };
const quickTemplate: TemplateNode = { type: 'label', value: '$title' };

const membershipRaw = {
	doctype: 'CompanyMembership',
	domain: 'crm',
	schema_version: 1,
	fields: { role: { type: 'string' } }
};

let listCalls = 0;

/** Minimal driver covering only the chain the loader walks. */
function fakeDriver(opts: {
	/** Native definition map (mock-driver path). Omit for the registry path. */
	definitions?: Map<string, Record<string, unknown>>;
	/** `core.DocType` list rows (registry path) — the row data IS the definition record. */
	docTypeRows?: Array<Record<string, unknown>>;
	/** `document_view` children of the relation doctype projection. */
	views?: ViewChild[];
	/** Make the `core.DocType` list reject. */
	failDefs?: boolean;
}): DataDriver {
	listCalls = 0;
	const childChain = {
		children: () => ({
			list: async () => ({ data: opts.views ?? [], meta: { count: 0, more: false } })
		})
	};
	const doctypeChain = {
		list: async () => {
			listCalls++;
			if (opts.failDefs) throw new Error('boom');
			return {
				data: (opts.docTypeRows ?? []).map((data) => ({ data, meta: { id: 'x' } })),
				meta: { count: 0, more: false }
			};
		},
		doc: () => childChain
	};
	const domain = { doctype: () => doctypeChain };
	return {
		...(opts.definitions ? { doctypeDefinitions: opts.definitions } : {}),
		domain: () => domain
	} as unknown as DataDriver;
}

const viewRow = (kind: string, template?: TemplateNode): ViewChild => ({
	data: { kind, template },
	meta: { id: `crm.CompanyMembership.views.${kind}` }
});

describe('relation def resolution', () => {
	it('parses from the native mock-driver map without a registry fetch', async () => {
		const driver = fakeDriver({
			definitions: new Map([['crm.CompanyMembership', membershipRaw]])
		});
		const update = await loadRelationTemplates(
			driver,
			'crm.CompanyMembership',
			{},
			{ editable: false }
		);
		expect(update.relationDef?.doctype).toBe('CompanyMembership');
		expect(update.relationDef?.domain).toBe('crm');
		expect(update.relationDef?.schema_version).toBe(1);
		expect(listCalls).toBe(0);
	});

	it('fetches the registry snapshot when the driver has no native map', async () => {
		const driver = fakeDriver({
			docTypeRows: [membershipRaw],
			views: [viewRow('inline', inlineTemplate)]
		});
		const update = await loadRelationTemplates(
			driver,
			'crm.CompanyMembership',
			{},
			{ editable: false }
		);
		expect(update.relationDef?.doctype).toBe('CompanyMembership');
		expect(listCalls).toBe(1);
	});

	it('omits relationDef when the doctype is unknown', async () => {
		const driver = fakeDriver({ definitions: new Map() });
		const update = await loadRelationTemplates(driver, 'crm.Missing', {}, { editable: false });
		expect(update.relationDef).toBeUndefined();
	});

	it('propagates a failing registry fetch', async () => {
		const driver = fakeDriver({ failDefs: true });
		await expect(
			loadRelationTemplates(driver, 'crm.CompanyMembership', {}, { editable: true })
		).rejects.toThrow('boom');
	});
});

describe('template kind selection', () => {
	it('editable mode loads the form template', async () => {
		const driver = fakeDriver({
			definitions: new Map([['crm.CompanyMembership', membershipRaw]]),
			views: [viewRow('form', formTemplate)]
		});
		const update = await loadRelationTemplates(
			driver,
			'crm.CompanyMembership',
			{},
			{ editable: true }
		);
		expect(update.formTemplate).toBe(formTemplate);
		expect(update.inlineTemplate).toBeUndefined();
	});

	it('editable mode yields a settled null when no form view exists', async () => {
		// The merge contract the renderer relies on: the key is PRESENT with
		// `null` ("no stored view — walk the definition"), never absent —
		// an absent key would leave the renderer's cache at "not loaded".
		const driver = fakeDriver({
			definitions: new Map([['crm.CompanyMembership', membershipRaw]])
		});
		const update = await loadRelationTemplates(
			driver,
			'crm.CompanyMembership',
			{},
			{ editable: true }
		);
		expect('formTemplate' in update).toBe(true);
		expect(update.formTemplate).toBeNull();
	});

	it('read mode loads the inline template', async () => {
		const driver = fakeDriver({
			definitions: new Map([['crm.CompanyMembership', membershipRaw]]),
			views: [viewRow('inline', inlineTemplate)]
		});
		const update = await loadRelationTemplates(
			driver,
			'crm.CompanyMembership',
			{},
			{ editable: false }
		);
		expect(update.inlineTemplate).toBe(inlineTemplate);
		expect(update.formTemplate).toBeUndefined();
	});

	it('read mode falls back to quickView when no inline kind exists', async () => {
		const driver = fakeDriver({
			definitions: new Map([['crm.CompanyMembership', membershipRaw]]),
			views: [viewRow('quickView', quickTemplate)]
		});
		const update = await loadRelationTemplates(
			driver,
			'crm.CompanyMembership',
			{},
			{ editable: false }
		);
		expect(update.inlineTemplate).toBe(quickTemplate);
	});

	it('read mode yields null when neither inline nor quickView exists', async () => {
		const driver = fakeDriver({
			definitions: new Map([['crm.CompanyMembership', membershipRaw]]),
			views: [viewRow('form', formTemplate)]
		});
		const update = await loadRelationTemplates(
			driver,
			'crm.CompanyMembership',
			{},
			{ editable: false }
		);
		expect(update.inlineTemplate).toBeNull();
	});
});

describe('load-once cache contract', () => {
	const cachedDef = parseDoctypeDef(membershipRaw);

	it('skips the def fetch when already cached', async () => {
		const driver = fakeDriver({
			definitions: new Map([['crm.CompanyMembership', membershipRaw]]),
			views: [viewRow('inline', inlineTemplate)]
		});
		const update = await loadRelationTemplates(
			driver,
			'crm.CompanyMembership',
			{ relationDef: cachedDef },
			{ editable: false }
		);
		expect(update.relationDef).toBeUndefined();
		expect(update.inlineTemplate).toBe(inlineTemplate);
		expect(listCalls).toBe(0);
	});

	it('skips the form fetch when already loaded', async () => {
		const driver = fakeDriver({
			definitions: new Map([['crm.CompanyMembership', membershipRaw]])
		});
		const update = await loadRelationTemplates(
			driver,
			'crm.CompanyMembership',
			{ relationDef: cachedDef, formTemplate: null },
			{ editable: true }
		);
		expect(update).toEqual({});
	});

	it('skips the inline fetch when already loaded', async () => {
		const driver = fakeDriver({
			definitions: new Map([['crm.CompanyMembership', membershipRaw]])
		});
		const update = await loadRelationTemplates(
			driver,
			'crm.CompanyMembership',
			{ relationDef: cachedDef, inlineTemplate: null },
			{ editable: false }
		);
		expect(update).toEqual({});
	});

	it('loads only the missing piece (def cached, template missing)', async () => {
		const driver = fakeDriver({
			definitions: new Map([['crm.CompanyMembership', membershipRaw]]),
			views: [viewRow('inline', inlineTemplate)]
		});
		const update = await loadRelationTemplates(
			driver,
			'crm.CompanyMembership',
			{ relationDef: cachedDef },
			{ editable: false }
		);
		expect(update.relationDef).toBeUndefined();
		expect(update.inlineTemplate).toBe(inlineTemplate);
	});
});
