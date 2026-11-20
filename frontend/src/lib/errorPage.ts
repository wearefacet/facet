// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Classification of the global error page (`src/routes/+error.svelte`).
 *
 * The page kind must come from structured data, never from error-message text.
 * SvelteKit tracks the failing HTTP status in `page.status` — on
 * the SSR response, on hydration, and on every client-side navigation.
 * `page.error` is only the `App.Error` body (`{ message }`) and carries a
 * status only when a `handleError` hook attaches one, so that status wins
 * when present.
 */

/** The error page variants `NotFoundPage` renders. */
export type ErrorPageKind = '404' | '410' | '500';

/**
 * Route ids whose page reads a single document — the show page and the edit
 * form. Both fail with the backend's `410` tombstone status.
 */
const DOCUMENT_ROUTE_IDS = new Set([
	'/[domain=notApi]/[doctype]/[id]',
	'/[domain=notApi]/[doctype]/[id]/edit'
]);

/** The `{ domain, doctype, id }` triple the history route needs. */
interface DocumentParams {
	domain: string;
	doctype: string;
	id: string;
}

/**
 * The document params behind a failed page, when its audit trail is reachable.
 *
 * A `410` on the show or edit load means the document is a tombstone; its
 * mutation history stays readable, so the error page can offer a History
 * shortcut to `/{domain}/{doctype}/{id}/history`. Returns `undefined` for any
 * other route, and when the router rendered the error page without route
 * context (unmatched route, redirect loop, a data request that failed at the
 * network level) — there the shortcut stays hidden.
 */
export function documentHistoryParams(
	routeId: string | null | undefined,
	params: Record<string, string | undefined>
): DocumentParams | undefined {
	if (!routeId || !DOCUMENT_ROUTE_IDS.has(routeId)) return undefined;
	const { domain, doctype, id } = params;
	if (!domain || !doctype || !id) return undefined;
	return { domain, doctype, id };
}

/** Classify the error page kind from the structured fields of a page error. */
export function errorPageKind(input: {
	/** Status carried on the error body itself, when one exists. */
	errorStatus?: number;
	/** SvelteKit's tracked status for the failed navigation (`page.status`). */
	pageStatus: number;
	/** The error body message — read only when no status is usable. */
	message?: string;
}): ErrorPageKind {
	const status = input.errorStatus ?? (input.pageStatus >= 400 ? input.pageStatus : 500);
	if (status === 404) return '404';
	if (status === 410) return '410';

	// Last resort: no status anywhere. The resolvers phrase genuine misses as
	// `Doctype X.Y not found` / `Domain X not found`, so a status-less error
	// with such a message renders as a 404; anything else is a server error.
	const hasStatus = input.errorStatus !== undefined || input.pageStatus >= 400;
	if (!hasStatus && input.message && /not found/i.test(input.message)) return '404';
	return '500';
}
