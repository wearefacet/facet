// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect, vi } from 'vitest';
import {
	createDocumentView,
	updateDocumentView,
	viewCollectionPath,
	viewDocumentPath,
	ViewAuthoringError
} from './viewAuthoring.js';

/** A `fetch`-shaped stub recording its calls and answering `res`. */
function fakeFetch(res: Response) {
	return vi.fn(async (_url: string, _init?: RequestInit) => res);
}

function jsonResponse(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'Content-Type': 'application/json' }
	});
}

describe('viewAuthoring', () => {
	it('builds the child routes under the encoded parent doctype', () => {
		expect(viewCollectionPath('hr.Employee')).toBe('/Api/core/DocType/hr.Employee/document_view');
		expect(viewDocumentPath('hr.Employee', 'view-1')).toBe(
			'/Api/core/DocType/hr.Employee/document_view/view-1'
		);
	});

	it('POSTs a create with the view content and returns the child id', async () => {
		const fetchImpl = fakeFetch(jsonResponse({ data: {}, meta: { id: 'dv-1' } }, 201));
		const id = await createDocumentView(fetchImpl, 'hr.Employee', 'card', { type: 'col' });

		expect(id).toBe('dv-1');
		const [url, init] = fetchImpl.mock.calls[0];
		expect(url).toBe('/Api/core/DocType/hr.Employee/document_view');
		expect(init?.method).toBe('POST');
		expect(JSON.parse(String(init?.body))).toEqual({
			parent_doctype: 'hr.Employee',
			kind: 'card',
			template: { type: 'col' }
		});
	});

	it('PATCHes a stored view with the template only', async () => {
		const fetchImpl = fakeFetch(jsonResponse({ data: {} }));
		await updateDocumentView(fetchImpl, 'hr.Employee', 'dv-1', { type: 'col' });

		const [url, init] = fetchImpl.mock.calls[0];
		expect(url).toBe('/Api/core/DocType/hr.Employee/document_view/dv-1');
		expect(init?.method).toBe('PATCH');
		expect(JSON.parse(String(init?.body))).toEqual({ template: { type: 'col' } });
	});

	it('throws the backend message on a rejected write', async () => {
		const fetchImpl = fakeFetch(jsonResponse({ error: 'Duplicate view kind' }, 422));
		const err = await createDocumentView(fetchImpl, 'hr.Employee', 'view', {}).catch((e) => e);

		expect(err).toBeInstanceOf(ViewAuthoringError);
		expect(err.message).toBe('Duplicate view kind');
		expect(err.status).toBe(422);
	});
});
