// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Write client for `core.DocumentView` templates, used by the Builder Views
 * tab.
 *
 * Views are children of the `core.DocType` projection: the child list route
 * (`GET /Api/core/DocType/<parent>/document_view`) feeds the preview, and the
 * create route (`POST /Api/core/DocType/<parent>/document_view`) or the child
 * update route (`PATCH /Api/core/DocType/<parent>/document_view/<id>`) writes
 * them back. The parent linkage rides the path (`meta.parent_id`); the body
 * carries the view content only.
 *
 * Every function takes an injectable `fetchImpl` — components pass `apiFetch`
 * so token refresh and 401 recovery stay in the loop, stories pass a fake.
 * A non-2xx response throws {@link ViewAuthoringError} carrying the backend
 * message.
 */

import type { ViewKind } from './previewDocument.js';

export type ViewTemplate = Record<string, unknown>;

/** `fetch`-compatible signature — `apiFetch` satisfies it. */
export type ViewFetch = (url: string, init?: RequestInit) => Promise<Response>;

/** A rejected write, carrying the backend's message when it sent one. */
export class ViewAuthoringError extends Error {
	constructor(
		message: string,
		readonly status: number
	) {
		super(message);
		this.name = 'ViewAuthoringError';
	}
}

/** Child collection path of one doctype's `core.DocumentView` rows. */
export function viewCollectionPath(parentDoctype: string): string {
	return `/Api/core/DocType/${encodeURIComponent(parentDoctype)}/document_view`;
}

/** Child document path of one stored view. */
export function viewDocumentPath(parentDoctype: string, id: string): string {
	return `${viewCollectionPath(parentDoctype)}/${encodeURIComponent(id)}`;
}

async function readError(res: Response): Promise<never> {
	const body = (await res.json().catch(() => ({}))) as { error?: unknown };
	const message = typeof body.error === 'string' ? body.error : `HTTP ${res.status}`;
	throw new ViewAuthoringError(message, res.status);
}

/**
 * Create the view of one kind under its doctype. Returns the new child id.
 */
export async function createDocumentView(
	fetchImpl: ViewFetch,
	parentDoctype: string,
	kind: ViewKind,
	template: ViewTemplate
): Promise<string> {
	const res = await fetchImpl(viewCollectionPath(parentDoctype), {
		method: 'POST',
		headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest' },
		body: JSON.stringify({ parent_doctype: parentDoctype, kind, template })
	});
	if (!res.ok) await readError(res);
	const body = (await res.json().catch(() => ({}))) as { meta?: { id?: unknown }; id?: unknown };
	const id = body.meta?.id ?? body.id;
	if (typeof id !== 'string' || id.length === 0) {
		throw new ViewAuthoringError('The create response carried no document id', res.status);
	}
	return id;
}

/**
 * Replace the template of a stored view. The body carries `template` only —
 * `kind` and `parent_doctype` stay as stored.
 */
export async function updateDocumentView(
	fetchImpl: ViewFetch,
	parentDoctype: string,
	id: string,
	template: ViewTemplate
): Promise<void> {
	const res = await fetchImpl(viewDocumentPath(parentDoctype, id), {
		method: 'PATCH',
		headers: { 'Content-Type': 'application/json', 'X-Requested-With': 'XMLHttpRequest' },
		body: JSON.stringify({ template })
	});
	if (!res.ok) await readError(res);
}
