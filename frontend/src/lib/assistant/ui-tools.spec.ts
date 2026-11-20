// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it } from 'vitest';
import type { TemplateNode } from '$lib/template-types.js';
import {
	UI_TOOL_NAMES,
	buildPreviewDocument,
	fakeFieldValue,
	isNavigateChunk,
	isWorkspaceNavigateChunk,
	parseGoToPage,
	parseNavigateTarget,
	parseShowDocuments,
	parseViewPreview,
	templateFieldKeys
} from './ui-tools.js';

describe('parseViewPreview', () => {
	it('parses a valid document-kind payload', () => {
		const spec = parseViewPreview(
			JSON.stringify({
				kind: 'document',
				template: { type: 'label', value: '$name' },
				title: 'Show view'
			})
		);
		expect(spec).toEqual({
			kind: 'document',
			template: { type: 'label', value: '$name' },
			title: 'Show view'
		});
	});

	it('parses a collection-kind payload with config', () => {
		const spec = parseViewPreview(
			JSON.stringify({
				kind: 'collection',
				surface: 'table',
				config: { columns: [{ key: 'name' }] },
				sample_data: { name: 'Acme' }
			})
		);
		expect(spec).toEqual({
			kind: 'collection',
			surface: 'table',
			config: { columns: [{ key: 'name' }] },
			sample_data: { name: 'Acme' }
		});
	});

	it('rejects unknown kinds and bad surfaces', () => {
		expect(parseViewPreview(JSON.stringify({ kind: 'grid' }))).toBeNull();
		expect(parseViewPreview(JSON.stringify({ kind: 'collection', surface: 'kanban' }))).toBeNull();
		expect(parseViewPreview(JSON.stringify({ kind: 'document', template: [] }))).toBeNull();
		expect(parseViewPreview('not json')).toBeNull();
		expect(parseViewPreview(undefined)).toBeNull();
	});
});

describe('parseGoToPage', () => {
	it('parses known pages only', () => {
		expect(parseGoToPage(JSON.stringify({ page: 'overview' }))).toEqual({ page: 'overview' });
		expect(parseGoToPage(JSON.stringify({ page: 'kanban' }))).toBeNull();
		expect(parseGoToPage(undefined)).toBeNull();
	});

	it('keeps the optional doctype, tab and path fields', () => {
		expect(
			parseGoToPage(
				JSON.stringify({ page: 'doctype', doctype_id: 'logistics.Shipment', tab: 'views' })
			)
		).toEqual({ page: 'doctype', doctype_id: 'logistics.Shipment', tab: 'views' });
		expect(parseGoToPage(JSON.stringify({ page: 'preview', path: ['_abc', 'Widget'] }))).toEqual({
			page: 'preview',
			path: ['_abc', 'Widget']
		});
	});
});

describe('isNavigateChunk', () => {
	it('matches only the resolved go_to_page chunk with arguments', () => {
		const ok = {
			kind: 'tool_call',
			name: 'go_to_page',
			status: 'ok',
			arguments: '{"page":"overview"}'
		} as const;
		expect(isNavigateChunk(ok)).toBe(true);
		expect(isNavigateChunk({ kind: 'tool_call', name: 'go_to_page', status: 'ok' })).toBe(false);
		expect(isNavigateChunk({ kind: 'tool_call', name: 'go_to_page', status: 'running' })).toBe(
			false
		);
	});
});

describe('isWorkspaceNavigateChunk', () => {
	it('matches only the resolved workspace navigate chunk with arguments', () => {
		const ok = {
			kind: 'tool_call',
			name: 'navigate',
			status: 'ok',
			arguments: '{"target":"domain","domain":"crm"}'
		} as const;
		expect(isWorkspaceNavigateChunk(ok)).toBe(true);
		expect(isWorkspaceNavigateChunk({ kind: 'tool_call', name: 'navigate', status: 'ok' })).toBe(
			false
		);
		expect(
			isWorkspaceNavigateChunk({ kind: 'tool_call', name: 'navigate', status: 'running' })
		).toBe(false);
		expect(isNavigateChunk(ok)).toBe(false);
	});
});

describe('parseNavigateTarget', () => {
	it('parses the document target', () => {
		const args = parseNavigateTarget(
			JSON.stringify({
				target: 'document',
				domain: 'crm',
				doctype: 'Customer',
				id: 'crm.Customer.99'
			})
		);
		expect(args).toEqual({
			target: 'document',
			domain: 'crm',
			doctype: 'Customer',
			id: 'crm.Customer.99'
		});
	});

	it('parses the collection target with and without a view', () => {
		const plain = parseNavigateTarget(
			JSON.stringify({ target: 'collection', domain: 'crm', doctype: 'Customer' })
		);
		expect(plain).toEqual({ target: 'collection', domain: 'crm', doctype: 'Customer' });

		const paged = parseNavigateTarget(
			JSON.stringify({
				target: 'collection',
				domain: 'crm',
				doctype: 'Customer',
				view_slug: 'active-table'
			})
		);
		expect(paged!.view_slug).toBe('active-table');
	});

	it('parses the domain target', () => {
		const args = parseNavigateTarget(JSON.stringify({ target: 'domain', domain: 'logistics' }));
		expect(args).toEqual({ target: 'domain', domain: 'logistics' });
	});

	it('returns null for an unknown target or a broken payload', () => {
		expect(parseNavigateTarget(JSON.stringify({ target: 'kanban', domain: 'crm' }))).toBeNull();
		expect(parseNavigateTarget(JSON.stringify({ target: 'domain' }))).toBeNull();
		expect(parseNavigateTarget(JSON.stringify({ target: 'document', domain: 'crm' }))).toBeNull();
		expect(
			parseNavigateTarget(
				JSON.stringify({ target: 'collection', domain: 'crm', doctype: 'Customer', view_slug: 7 })
			)
		).toBeNull();
		expect(parseNavigateTarget('not json')).toBeNull();
		expect(parseNavigateTarget(undefined)).toBeNull();
	});
});

describe('parseShowDocuments', () => {
	const args = JSON.stringify({
		domain: 'crm',
		doctype: 'Customer',
		ids: ['crm.Customer.1', 'crm.Customer.2'],
		display: 'card'
	});

	it('parses the arguments with the card display as default', () => {
		expect(
			parseShowDocuments(JSON.stringify({ domain: 'crm', doctype: 'Customer', ids: ['a'] }))
		).toEqual({ domain: 'crm', doctype: 'Customer', ids: ['a'], display: 'card' });
		expect(parseShowDocuments(args)).toEqual({
			domain: 'crm',
			doctype: 'Customer',
			ids: ['crm.Customer.1', 'crm.Customer.2'],
			display: 'card'
		});
	});

	it('narrows the ids to the rendered list from the tool ack', () => {
		const ack = JSON.stringify({
			ok: true,
			data: { rendered: ['crm.Customer.2'], skipped: ['crm.Customer.1'], display: 'card' }
		});
		expect(parseShowDocuments(args, ack)).toEqual({
			domain: 'crm',
			doctype: 'Customer',
			ids: ['crm.Customer.2'],
			display: 'card'
		});
	});

	it('keeps a non-ok envelope as the requested ids', () => {
		const ack = JSON.stringify({ ok: false, error: 'Refused' });
		expect(parseShowDocuments(args, ack)?.ids).toEqual(['crm.Customer.1', 'crm.Customer.2']);
	});

	it('returns null for malformed arguments', () => {
		expect(parseShowDocuments(undefined)).toBeNull();
		expect(parseShowDocuments('not json')).toBeNull();
		expect(parseShowDocuments(JSON.stringify({ domain: 'crm', ids: ['a'] }))).toBeNull();
		expect(
			parseShowDocuments(JSON.stringify({ domain: 'crm', doctype: 'Customer', ids: [] }))
		).toBeNull();
		expect(
			parseShowDocuments(
				JSON.stringify({ domain: 'crm', doctype: 'Customer', ids: ['a'], display: 'grid' })
			)
		).toBeNull();
	});

	it('returns null when the ack rendered list is empty', () => {
		const ack = JSON.stringify({ ok: true, data: { rendered: [], skipped: ['a'] } });
		expect(
			parseShowDocuments(JSON.stringify({ domain: 'crm', doctype: 'Customer', ids: ['a'] }), ack)
		).toBeNull();
	});
});

describe('UI_TOOL_NAMES', () => {
	it('mirrors the union of the two backend registrar UI-tool lists', () => {
		expect([...UI_TOOL_NAMES].sort()).toEqual([
			'go_to_page',
			'navigate',
			'preview_view',
			'show_documents'
		]);
	});
});

describe('templateFieldKeys', () => {
	it('collects $refs and field bindings in order, without duplicates', () => {
		const template: TemplateNode = {
			type: 'col',
			children: [
				{ type: 'label', value: '$name' },
				{
					type: 'section',
					label: 'G',
					children: [
						{ type: 'field', label: 'E', value: '$email' },
						{ type: 'field', label: 'N', value: '$name' }
					]
				},
				{ type: 'object', field: 'address', children: [{ type: 'label', value: '$city' }] }
			]
		};
		expect(templateFieldKeys(template)).toEqual(['name', 'email', 'address', 'city']);
	});

	it('excludes scope-internal tokens so previews do not fake unbound bindings', () => {
		// $item / $this / $self never resolve against the top-level document;
		// $value binds only inside a scalar-array iteration. Faking any of
		// them masked an unbound token as a working binding.
		const template: TemplateNode = {
			type: 'col',
			children: [
				{ type: 'label', value: '$item' },
				{ type: 'label', value: '$this' },
				{ type: 'label', value: '$self' },
				{ type: 'label', value: '$page' },
				{
					type: 'array',
					field: 'pages',
					children: [{ type: 'capsule', value: 'p. $value' }]
				}
			]
		};
		expect(templateFieldKeys(template)).toEqual(['pages']);
	});
});

describe('fakeFieldValue', () => {
	it('is deterministic for the same key', () => {
		expect(fakeFieldValue('customer_name')).toBe(fakeFieldValue('customer_name'));
	});

	it('shapes common field families', () => {
		expect(fakeFieldValue('customer_id')).toMatch(/^core\.doc_/);
		expect(fakeFieldValue('contact_email')).toMatch(/@/);
		expect(fakeFieldValue('created_at')).toMatch(/Z$/);
		expect(typeof fakeFieldValue('item_count')).toBe('number');
		expect(fakeFieldValue('total_amount')).toEqual({
			value: expect.any(String),
			currency: 'USD'
		});
	});
});

describe('buildPreviewDocument', () => {
	it('generates values for every template field and lets sample_data win', () => {
		const { data } = buildPreviewDocument({
			kind: 'document',
			template: {
				type: 'col',
				children: [
					{ type: 'label', value: '$name' },
					{ type: 'label', value: '$status' }
				]
			},
			sample_data: { name: 'Aurora' }
		});
		expect(data['name']).toBe('Aurora');
		expect(data['status']).toBe('active');
	});
});
