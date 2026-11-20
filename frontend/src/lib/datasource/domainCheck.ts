// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Draft domain diagnostics client.
 *
 * Wraps the Facet backend endpoint
 *   GET /Api/core/Domain/:id/check
 * which aggregates `Doctype::Check` issues across every doctype owned by the
 * domain. Used by the Builder landing page (issue-count chips) and the
 * draft DomainEditor's `Check` tab + Publish confirmation dialog.
 *
 * The endpoint is gated by `write core.Domain` on the server — the same
 * permission that gates the publish action. Unauthorised callers get a 403.
 */

import type { GrantTicket } from '$lib/components/features/configure/domainGrants.js';

export type CheckSeverity = 'warning' | 'info';

export type CheckCategory =
	| 'reference'
	| 'replication'
	| 'children'
	| 'composition'
	| 'sidecar'
	| 'defaults'
	| 'no_doctypes';

export interface DomainIssue {
	severity: CheckSeverity;
	category: CheckCategory;
	message: string;
	/** Present when the issue is tied to a single field, omitted otherwise. */
	field?: string;
}

export interface DoctypeCheckResult {
	/** Qualified doctype id, e.g. `_abc.Order`. */
	doctype_id: string;
	/** Count of warning-severity issues only (informational notices excluded). */
	issue_count: number;
	issues: DomainIssue[];
	/** Informational (`info`-severity, `defaults`-category) notices. */
	notices: DomainIssue[];
}

export interface DomainCheckResult {
	/** Draft (or live) domain id, e.g. `_abc`. */
	domain: string;
	/** Sum of `domain_issues` + every doctype's `issue_count`. */
	issue_count: number;
	domain_issues: DomainIssue[];
	doctypes: DoctypeCheckResult[];
}

/** Result of a successful publish — the new domain id plus the
 *  grant-ticket report (one entry per producer whose grant the publish
 *  filed or merged; see `domainGrants.ts` for the model rules). */
export interface PublishDomainResult {
	domain: string;
	grant_tickets: GrantTicket[];
	/** Documents carried from the draft, as reported by the backend. */
	documents_imported?: number;
}

/**
 * Draft documents to carry into the publish target.
 *
 * `doctypes: null` imports every draft doctype; an empty array imports none.
 * A doctype the live target already defines is refused by the backend, so the
 * dialog disables it before submit.
 */
export interface PublishDocumentsSelection {
	import: boolean;
	doctypes?: string[] | null;
}

export class DomainCheckError extends Error {
	constructor(
		public readonly status: number,
		message: string
	) {
		super(message);
		this.name = 'DomainCheckError';
	}
}

type FetchFn = typeof fetch;

/**
 * Fetches the aggregate diagnostic result for the given draft domain id.
 *
 * @param domainId Domain id (e.g. `_abc`).
 * @param fetchFn  SvelteKit `event.fetch` in load functions so relative URLs
 *                 resolve during SSR; the global `fetch` otherwise. The
 *                 session cookie is sent via `apiFetch`'s `credentials: 'include'`.
 * @throws {DomainCheckError} on a non-200 response.
 */
export async function fetchDomainCheck(
	domainId: string,
	fetchFn?: FetchFn
): Promise<DomainCheckResult> {
	const { apiFetch } = await import('$lib/session.svelte');
	const url = `/Api/core/Domain/${encodeURIComponent(domainId)}/check`;
	const res = await apiFetch(url, { method: 'GET' }, { fetch: fetchFn });
	if (!res.ok) {
		let message = `Domain check failed: HTTP ${res.status}`;
		try {
			const body = (await res.json()) as { error?: string };
			if (body?.error) message = body.error;
		} catch {
			// Leave the generic message.
		}
		throw new DomainCheckError(res.status, message);
	}
	const body = (await res.json()) as { data: DomainCheckResult };
	return body.data;
}

/**
 * Publishes a draft domain into a fresh real-named domain, or over an
 * existing one when `overwrite` is set.
 *
 * Wraps `POST /Api/core/Domain/:id/publish` with body
 * `{"target_name": "…", "overwrite": …, "documents": …}`. On success returns
 * the new domain id plus the grant-ticket report — one entry per producer
 * domain whose grant the publish filed or merged (empty when the draft
 * declares no outbound cross-domain edge).
 *
 * When `overwrite` is `false` and the target already exists, the backend
 * returns 409. When `overwrite` is `true`, the backend runs the version
 * gate (a doctype whose structure changed must carry `schema_version =
 * live + 1` and a migration entry for that gap) and rejects with 422 if
 * the gate fails.
 *
 * `documents` carries the selected draft doctypes' rows into the target.
 * The backend refuses (`422`) a doctype the draft does not define and, on an
 * overwrite, a doctype the live target already defines.
 *
 * @throws {DomainCheckError} on a non-200 response.
 */
export async function publishDraftDomain(
	draftDomainId: string,
	targetName: string,
	overwrite = false,
	fetchFn?: FetchFn,
	documents?: PublishDocumentsSelection
): Promise<PublishDomainResult> {
	const { apiFetch } = await import('$lib/session.svelte');
	const url = `/Api/core/Domain/${encodeURIComponent(draftDomainId)}/publish`;
	const payload: Record<string, unknown> = { target_name: targetName, overwrite };
	if (documents?.import) payload.documents = documents;
	const res = await apiFetch(
		url,
		{
			method: 'POST',
			headers: { 'Content-Type': 'application/json' },
			body: JSON.stringify(payload)
		},
		{ fetch: fetchFn }
	);
	if (!res.ok) {
		let message = `Publish failed: HTTP ${res.status}`;
		try {
			const body = (await res.json()) as { error?: string };
			if (body?.error) message = body.error;
		} catch {
			// Leave the generic message.
		}
		throw new DomainCheckError(res.status, message);
	}
	const body = (await res.json()) as { data: PublishDomainResult };
	return body.data;
}
