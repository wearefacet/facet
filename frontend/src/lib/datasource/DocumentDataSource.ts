// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import {
	DataSourceError,
	type BackrefsParams,
	type BackrefsResponse,
	type DocumentResponse,
	type HistoryParams,
	type HistoryResponse,
	type ListParams,
	type ListResponse,
	type RollbackResponse,
	type ValidationError
} from './types.js';
import type { DataSource, DocumentRef } from './interface.js';
import { serializeFilterValue } from './filterParams.js';
import { parseLosslessJson } from './losslessJson.js';
import { apiFetch } from '../session.svelte';
import { documentShowCache } from './clientCache.js';

/**
 * Custom fetch type — accepts the native `fetch` or SvelteKit's `event.fetch`.
 *
 * When passed to a DataSource, it is forwarded to {@link apiFetch} as
 * `opts.fetch` so that relative URLs resolve during SSR and cookies are
 * forwarded — while `apiFetch` keeps its pre-emptive refresh and 401
 * recovery active. When omitted on the client, `apiFetch` falls back to
 * the global `fetch`.
 */
type FetchFn = typeof fetch;

// ── Helpers ──────────────────────────────────────────────────────────────────

function buildBasePath(baseUrl: string | undefined, domain: string, docType: string): string {
	const prefix = baseUrl ? `${baseUrl}` : '';
	return `${prefix}/Api/${domain}/${docType}`;
}

async function request<T>(url: string, options: RequestInit = {}, fetchFn?: FetchFn): Promise<T> {
	// Always route through `apiFetch` — it owns pre-emptive token refresh and
	// 401 recovery (`tryRefresh` + retry). Passing the injected `fetchFn` via
	// `opts.fetch` keeps SvelteKit's `event.fetch` semantics (relative-URL
	// resolution and cookie forwarding during SSR) without bypassing refresh,
	// which was the bug: when `event.fetch` was supplied from a load function,
	// `apiFetch` was skipped entirely and an expired access token produced a
	// raw 401 with no refresh attempt.
	const res = await apiFetch(
		url,
		{
			headers: { 'Content-Type': 'application/json', ...options.headers },
			credentials: 'include',
			...options
		},
		fetchFn ? { fetch: fetchFn } : undefined
	);

	if (!res.ok) {
		const body = (await res.json().catch(() => ({ error: res.statusText }))) as Record<
			string,
			unknown
		>;
		const message = typeof body.error === 'string' ? body.error : res.statusText;
		throw new DataSourceError(
			res.status,
			message,
			body.details as ValidationError[] | undefined,
			body
		);
	}

	// 204 No Content (e.g. delete)
	if (res.status === 204) return undefined as unknown as T;

	// The lossless parse keeps Int64 values beyond 2^53 exact — plain
	// `res.json()` rounds them to a double before any component renders.
	return parseLosslessJson(await res.text()) as T;
}

async function listRequest<T>(
	basePath: string,
	params?: ListParams,
	fetchFn?: FetchFn
): Promise<ListResponse<T>> {
	const query = new URLSearchParams();

	if (params?.page) query.set('page', String(params.page));
	if (params?.items) query.set('items', String(params.items));
	if (params?.filters) {
		for (const [key, value] of Object.entries(params.filters)) {
			query.set(`filters[${key}]`, serializeFilterValue(value));
		}
	}
	if (params?.sort && params.sort.length > 0) {
		query.set('sort', params.sort.join(','));
	}
	if (params?.aggregate) {
		query.set('aggregate', params.aggregate);
	}
	if (params?.includeDeleted) {
		query.set('deleted', 'true');
	}

	const qs = query.toString();
	const url = qs ? `${basePath}?${qs}` : basePath;
	return request<ListResponse<T>>(url, {}, fetchFn);
}

// ── DocumentRef implementation ───────────────────────────────────────────

class ConcreteDocumentRef<T = Record<string, unknown>> implements DocumentRef<T> {
	constructor(
		private readonly basePath: string,
		private readonly docId: string,
		private readonly fetchFn?: FetchFn
	) {}

	private get showUrl(): string {
		return `${this.basePath}/${this.docId}`;
	}

	show(): Promise<DocumentResponse<T>> {
		// Cache and dedupe by URL. Two capsules rendering the same reference
		// (e.g. `iam.Account/account_recruiter_kim` shown twice on a page) share one
		// fetch within the 60s TTL window. Returns a fresh parse of the JSON body
		// so callers can mutate the result without poisoning the cached value.
		return documentShowCache.get(this.showUrl, async () => {
			const res = await request<DocumentResponse<T>>(this.showUrl, {}, this.fetchFn);
			return structuredClone(res);
		}) as Promise<DocumentResponse<T>>;
	}

	update(diff: unknown): Promise<DocumentResponse<T>> {
		// Invalidate the cached show() result before the update lands — once the
		// PATCH returns, the next `show()` refetches the new version.
		documentShowCache.invalidate(this.showUrl);
		return request<DocumentResponse<T>>(
			this.showUrl,
			{ method: 'PATCH', body: JSON.stringify(diff) },
			this.fetchFn
		);
	}

	async delete(): Promise<void> {
		documentShowCache.invalidate(this.showUrl);
		await request(`${this.showUrl}`, { method: 'DELETE' }, this.fetchFn);
	}

	action(actionName: string, args?: Record<string, unknown>): Promise<DocumentResponse<T>> {
		// An action may mutate the document — invalidate the cached `show()` so
		// the next read observes the post-action state.
		documentShowCache.invalidate(this.showUrl);
		return request<DocumentResponse<T>>(
			`${this.showUrl}/${actionName}`,
			{ method: 'POST', body: JSON.stringify(args ?? {}) },
			this.fetchFn
		);
	}

	invalidate(): void {
		// Out-of-band mutations (bespoke endpoints) never reach the ref's own
		// invalidating paths (update / delete / action / rollback / restore).
		// The host calls this so the next `show()` refetches the new state.
		documentShowCache.invalidate(this.showUrl);
	}

	history(params?: HistoryParams): Promise<HistoryResponse> {
		const query = new URLSearchParams();
		if (params?.page) query.set('page', String(params.page));
		if (params?.items) query.set('items', String(params.items));
		if (params?.sort && params.sort.length > 0) query.set('sort', params.sort.join(','));
		if (params?.include) query.set('include', params.include);
		if (params?.filters) {
			for (const [k, v] of Object.entries(params.filters)) {
				query.set(`filters[${k}]`, serializeFilterValue(v));
			}
		}
		const qs = query.toString();
		const url = qs
			? `${this.basePath}/${this.docId}/history?${qs}`
			: `${this.basePath}/${this.docId}/history`;
		return request<HistoryResponse>(url, {}, this.fetchFn);
	}

	rollback(mutationId: string): Promise<RollbackResponse> {
		// A rollback rewrites the document state — invalidate the cached `show()` so
		// the next read reflects the rolled-back version.
		documentShowCache.invalidate(this.showUrl);
		return request<RollbackResponse>(
			`${this.showUrl}/rollback`,
			{ method: 'POST', body: JSON.stringify({ mutation_id: mutationId }) },
			this.fetchFn
		);
	}

	restore(): Promise<RollbackResponse> {
		// A restore rewrites the document state — invalidate the cached `show()`
		// so the next read reflects the restored version.
		documentShowCache.invalidate(this.showUrl);
		return request<RollbackResponse>(
			`${this.showUrl}/restore`,
			{ method: 'POST', body: JSON.stringify({}) },
			this.fetchFn
		);
	}

	backrefs(params?: BackrefsParams): Promise<BackrefsResponse> {
		const query = new URLSearchParams();
		if (params?.items) query.set('items', String(params.items));
		const qs = query.toString();
		const url = qs ? `${this.showUrl}/backrefs?${qs}` : `${this.showUrl}/backrefs`;
		return request<BackrefsResponse>(url, {}, this.fetchFn);
	}

	children<C = Record<string, unknown>>(relName: string): DataSource<C> {
		// Pass the parent collection path (without the relName) — `ChildScopedDataSource`
		// appends the relName itself to build child routes. Doubling it here would
		// produce `/Api/.../collection_view/collection_view` and hit a wrong route.
		const parentBase = `${this.basePath}/${this.docId}`;
		return new ChildScopedDataSource<C>(parentBase, relName, this.fetchFn);
	}

	sidecars<C = Record<string, unknown>>(segment: string): DataSource<C> {
		// Sidecar routes are URL-identical to child per-doc routes
		// (`/Api/:domain/:doctype/:id/:segment`), so the same scoped data source
		// serves both. The semantic difference (reference-column filtering)
		// lives in the backend route and in the mock driver.
		const parentBase = `${this.basePath}/${this.docId}`;
		return new ChildScopedDataSource<C>(parentBase, segment, this.fetchFn);
	}
}

// ── Child-scoped DataSource (used by children() on DocumentRef) ──────────

class ChildScopedDataSource<T = Record<string, unknown>> implements DataSource<T> {
	constructor(
		private readonly parentPath: string,
		private readonly relName: string,
		private readonly fetchFn?: FetchFn
	) {}

	private get basePath(): string {
		return `${this.parentPath}/${this.relName}`;
	}

	list(params?: ListParams): Promise<ListResponse<T>> {
		return listRequest<T>(this.basePath, params, this.fetchFn);
	}

	create(content: T): Promise<DocumentResponse<T>> {
		return request<DocumentResponse<T>>(
			this.basePath,
			{ method: 'POST', body: JSON.stringify(content) },
			this.fetchFn
		);
	}

	doc(id: string): DocumentRef<T> {
		return new ConcreteDocumentRef<T>(this.basePath, id, this.fetchFn);
	}
}

// ── Main export ──────────────────────────────────────────────────────────

/**
 * HTTP-backed DataSource that talks to the Facet REST API.
 *
 * Created with a domain and doctype name — every operation hits the
 * corresponding `/Api/:domain/:doctype` endpoint.
 *
 * @example
 * ```ts
 * const ds = new DocumentDataSource("hr", "Employee");
 *
 * // Collection ops
 * const list = await ds.list({ filters: { status__eq: "active" } });
 * // list.data => [{ data: { name: "Alice", status: "active" }, meta: { id: "hr.Employee.xxx", ... } }]
 * // list.meta => { count: 5, more: false }
 *
 * const emp  = await ds.create({ name: "Alice" });
 * // emp.data  => { name: "Alice" }
 * // emp.meta => { id, mid, domain, doc_type, version, ... }
 *
 * // Document ops
 * const doc  = await ds.doc("e1").show();
 * await ds.doc("e1").update({ name: "Alice", status: "active" });
 * await ds.doc("e1").delete();
 * await ds.doc("e1").action("promote", { level: 4 });
 *
 * // Child navigation
 * const careerDs = ds.doc("e1").children("career_events");
 * await careerDs.list();
 * await careerDs.doc("c3").show();
 * ```
 */
export class DocumentDataSource<T = Record<string, unknown>> implements DataSource<T> {
	private readonly basePath: string;

	/**
	 * @param domain   The domain name (e.g. "hr")
	 * @param docType  The doctype name (e.g. "Employee")
	 * @param baseUrl  Optional server root URL (e.g. "http://localhost:3000").
	 *                 If omitted, paths are relative (e.g. `/Api/{domain}/{docType}`).
	 *                 When provided via {@link DocumentDataDriver}, the URL is
	 *                 automatically supplied.
	 * @param fetchFn  Optional custom fetch — pass SvelteKit's `event.fetch` in
	 *                 load functions so relative URLs work during SSR. It is
	 *                 forwarded to {@link apiFetch} as `opts.fetch`, so
	 *                 token refresh and 401 recovery remain active regardless.
	 *                 When omitted, `apiFetch` uses the global `fetch`.
	 */
	constructor(
		public readonly domain: string,
		public readonly docType: string,
		private readonly baseUrl?: string,
		private readonly fetchFn?: FetchFn
	) {
		this.basePath = buildBasePath(baseUrl, domain, docType);
	}

	// ── Collection-level ────────────────────────────────────────────────

	list(params?: ListParams): Promise<ListResponse<T>> {
		return listRequest<T>(this.basePath, params, this.fetchFn);
	}

	create(content: T): Promise<DocumentResponse<T>> {
		return request<DocumentResponse<T>>(
			this.basePath,
			{ method: 'POST', body: JSON.stringify(content) },
			this.fetchFn
		);
	}

	// ── Document-level (via ref) ────────────────────────────────────────

	doc(id: string): DocumentRef<T> {
		return new ConcreteDocumentRef<T>(this.basePath, id, this.fetchFn);
	}
}
