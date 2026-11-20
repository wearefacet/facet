// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { memoryCache } from './cache.js';
import type { CacheStore } from './cache.js';
import { requestJson } from './http.js';
import type { HttpMethod, RequestOptions } from './http.js';
import { serializeListParams } from './query.js';
import type { ListParams } from './query.js';
import { createArtifactHandle } from './artifacts.js';
import type { ArtifactHandle } from './artifacts.js';
import { createRealtimeHandle } from './realtime.js';
import type { RealtimeHandle, RealtimeOptions } from './realtime.js';
import { filePartName } from './multipart.js';
import type { TokenProvider } from './auth/provider.js';
import { can as rightsCan, scopeAliases as rightsScopes } from './me.js';
import type { AssistantCapability, CanAnswer, Me } from './me.js';

// ── Response types ───────────────────────────────────────────────────────────

/** System metadata of one document, from the HTTP `meta` response field. */
export interface DocumentMeta {
	/** Document id (legacy dotted form). */
	id: string;
	/** Canonical URN, e.g. `urn:facet:hr:Employee:abc123`. */
	uri?: string;
	/** ULID of the last mutation applied to the document. */
	mid: string;
	domain: string;
	doc_type: string;
	version: number;
	schema_version: number;
	/** Human label. `null` when the doctype declares no display_name template. */
	display_name?: string | null;
	created_at: string;
	updated_at: string;
	/** Parent document id for child doctypes. Absent on aggregate-root documents. */
	parent_id?: string;
}

/** Response of one single-document endpoint: show, create, update, or action. */
export interface DocumentResponse<T = Record<string, unknown>> {
	data: T;
	meta: DocumentMeta;
	/** Set only on a compound create with nested children, grouped by relationship name. */
	children?: Record<string, DocumentResponse<unknown>[]>;
}

/** One row of a collection response: the same shape as a single-document response. */
export type ListItem<T = Record<string, unknown>> = { data: T; meta: DocumentMeta };

/** Response of one collection endpoint: a list or a child list. */
export interface ListResponse<T = Record<string, unknown>> {
	data: ListItem<T>[];
	meta: {
		/** Capped row count. At most 1000. */
		count: number;
		/** True when the filter matches more rows than this page holds. */
		more: boolean;
	};
}

/**
 * One page of a collection list, plus the pager.
 *
 * `next()` advances `page` while `meta.more` is true and returns the next
 * page. It returns `null` when `more` is false — the sentinel for "no next
 * page". An aggregate call has no pages; `next()` returns `null` there too.
 */
export interface ListPage<T = Record<string, unknown>> extends ListResponse<T> {
	next(): Promise<ListPage<T> | null>;
}

/** History query parameters, accepted by `DocumentRef.history`. */
export interface HistoryParams {
	page?: number;
	items?: number;
	filters?: Record<string, unknown>;
	sort?: string[];
	/** Merge the readable child documents' mutations into the timeline. */
	include?: 'children';
}

/** One mutation record from the append-only audit log. */
export interface MutationRecord {
	/** ULID of the mutation. */
	id: string;
	domain: string;
	doc_type: string;
	/** Document the mutation applies to. */
	doc_id: string;
	/** Sequential per-document index. Starts at 1. */
	idx: number;
	/** One of `create`, `update`, `delete`, `snapshot`. */
	action: string;
	/** Identity that performed the mutation. */
	actioner_id: string;
	/** Action payload: content for create, diff for update, and so on. */
	arguments: Record<string, unknown>;
	/** Content paths whose values the server removed, because the role cannot see those fields. */
	redacted?: string[][];
	/** Authentication surface: `session`, `oauth_app`, `app_api_key`, `api_key`, `mcp`, `internal`. */
	channel: string;
	/** `app.App` projection id for an app token or app-owned API key; `null` otherwise. */
	app?: string | null;
	/** `api_keys.id` row ULID when a key performed the mutation; `null` otherwise. */
	api_key?: string | null;
	/** Role elected at authorize time on the MCP surface; `null` otherwise. */
	acting_role?: string | null;
	/** Direct trigger kind: `request`, `action`, `hook_event`, `rollback`, and others. */
	cause_kind: string;
	/** Action name, hook id, or replication binding descriptor; `null` when not applicable. */
	cause_name?: string | null;
	/** Resolved event name, such as `updated`; `null` when not applicable. */
	cause_event?: string | null;
	/** The document the cause ran on, as `domain.Doctype:id`; `null` when not applicable. */
	cause_source?: string | null;
	/** Mutation ULID of the direct trigger; `null` for root mutations. */
	cause_parent?: string | null;
	/** ULID of the root of the causal cluster. */
	cause_trace: string;
	/** When the server recorded the mutation. */
	emitted_at: string;
	/** Target document label. Set only in aggregate mode (`include: 'children'`). */
	display_name?: string | null;
}

/** Response of the document history endpoint. Same envelope as a list. */
export interface HistoryResponse {
	data: MutationRecord[];
	meta: {
		count: number;
		more: boolean;
	};
}

/** Backrefs query parameters, accepted by `DocumentRef.backrefs`. */
export interface BackrefsParams {
	/** Row cap. Server max 1000, default 100. */
	items?: number;
}

/** One referring document from the backlinks endpoint. */
export interface BackrefItem {
	id: string;
	domain: string;
	doc_type: string;
	/** Label from the referrer's projection row. `null` when its doctype declares no template. */
	display_name: string | null;
}

/** Response of the backrefs endpoint. */
export interface BackrefsResponse {
	data: BackrefItem[];
	meta: {
		/** Canonical URN the query ran against. */
		target: string;
		/** Number of returned rows. */
		total: number;
		/** True when the result reached the `items` cap. More referrers may exist. */
		capped: boolean;
	};
}

/** Response of the rollback and restore endpoints. */
export interface RollbackResponse {
	/** Restored document id. */
	id: string;
	domain: string;
	doc_type: string;
	/** ULID of the snapshot mutation the rollback wrote. */
	mut_id: string;
	/** Restored document content. */
	content: Record<string, unknown>;
	/** Document creation timestamp. Preserved across rollback. */
	created_at: string;
}

/** Options for a create or an update that carries file fields. */
export interface FilesOptions {
	/**
	 * One entry per `file` field, keyed by the normalized field path —
	 * `logo`, `items[0].file`. The handle builds one multipart request: a
	 * `$content` part with the document JSON plus one part per file. The
	 * uploads and the mutation share one server-side transaction.
	 */
	files?: Record<string, File | Blob>;
}

// ── Client surface ───────────────────────────────────────────────────────────

/** Options for `createFacetClient`. */
export interface FacetClientOptions {
	/** Server root, e.g. `https://facet.example.com`. Paths resolve against the origin. */
	baseUrl: string;
	/** Credential source. Omit it for a public endpoint. */
	auth?: TokenProvider;
	/** Replacement fetch; tests inject one. */
	fetchImpl?: typeof fetch;
	/**
	 * `true` turns on the in-memory ETag cache. A caller can pass a store
	 * instead. Default: off.
	 */
	cache?: boolean | CacheStore;
}

/** The client entry point. Created with `createFacetClient`. */
export interface FacetClient {
	/** A handle for one domain on the instance. */
	domain(domain: string): DomainHandle;

	/** The artifact handle: upload, grants, download. */
	artifacts: ArtifactHandle;

	/**
	 * The real-time handle of this client: one lazy socket, many
	 * subscriptions. The first call creates it; later calls return the same
	 * handle and ignore their options.
	 */
	realtime(options?: RealtimeOptions): RealtimeHandle;

	/**
	 * The `/Api/iam/me` payload for the current credential, cached after the
	 * first call. `refreshRights` forces a re-fetch (after a role switch on
	 * the consent screen, or a grant change).
	 */
	whoami(): Promise<Me>;

	/**
	 * What the current credential may do on `onPath` (`"crm.Company"`),
	 * from the cached manifest — `'all'` (unrestricted), `'scoped'` (granted
	 * with scope aliases; see `scopes`), or `'denied'`. Advisory only: the
	 * server re-resolves every request, so a `'denied'` call still reaches
	 * the server and answers 404/403 there. The first call fetches
	 * `/Api/iam/me`.
	 */
	can(action: string, onPath: string): Promise<CanAnswer>;

	/**
	 * The scope aliases the credential holds for `action` on `onPath` —
	 * `[]` when unrestricted. Denied answers yield `[]`; check `can`
	 * first. The first call fetches `/Api/iam/me`.
	 */
	scopes(action: string, onPath: string): Promise<string[]>;

	/** Re-fetches `/Api/iam/me` and replaces the cached payload. */
	refreshRights(): Promise<Me>;

	/**
	 * Assistant availability for the current credential — the gate
	 * `@facetapp/chat` consumers check before mounting the chat. For an app
	 * token the backend has already ANDed the role's `assistant_access` with
	 * the app's own `assistant_enabled` flag.
	 */
	assistant(): Promise<AssistantCapability>;
}

/** One domain on a Facet instance. */
export interface DomainHandle {
	/** A collection handle for one doctype in this domain. */
	doctype<T = Record<string, unknown>>(doctype: string): CollectionHandle<T>;
}

/**
 * A doctype collection: list, create, and document navigation.
 *
 * Aggregates ride `list({ aggregate, field })` — there are no separate
 * aggregate methods.
 */
export interface CollectionHandle<T = Record<string, unknown>> {
	/** List documents with pagination, filtering, and sorting. */
	list(params?: ListParams): Promise<ListPage<T>>;

	/** Create a document. Pass `{$content, $children}` for a compound create. */
	create(content: T, options?: FilesOptions): Promise<DocumentResponse<T>>;

	/** A document ref. No network call runs until you call a method on it. */
	doc(id: string): DocumentRef<T>;
}

/** A single document: read, write, audit, and sub-collection navigation. */
export interface DocumentRef<T = Record<string, unknown>> {
	/** Fetch the full document projection. */
	show(): Promise<DocumentResponse<T>>;

	/** Apply an incremental update. The diff rides the PATCH body as given. */
	update(diff: unknown, options?: FilesOptions): Promise<DocumentResponse<T>>;

	/** Soft-delete the document. */
	delete(): Promise<void>;

	/** Run a named action declared on the doctype. */
	action(actionName: string, args?: Record<string, unknown>): Promise<DocumentResponse<T>>;

	/** List the mutation history of the document, newest first by default. */
	history(params?: HistoryParams): Promise<HistoryResponse>;

	/** Roll the document back to the state it had at this mutation. */
	rollback(mutationId: string): Promise<RollbackResponse>;

	/** Restore a deleted (tombstoned) document. */
	restore(): Promise<RollbackResponse>;

	/** List the live documents that reference this document. */
	backrefs(params?: BackrefsParams): Promise<BackrefsResponse>;

	/** A collection handle for one child relationship of this document. */
	children<C = Record<string, unknown>>(relName: string): CollectionHandle<C>;

	/** A collection handle for one sidecar segment of this document. */
	sidecars<C = Record<string, unknown>>(segment: string): CollectionHandle<C>;
}

// ── Implementation ───────────────────────────────────────────────────────────

/** Shared credentials, fetch, and ETag store for every handle of one client. */
class Http {
	constructor(
		private readonly baseUrl: string,
		private readonly auth: TokenProvider | undefined,
		private readonly fetchImpl: typeof fetch | undefined,
		private readonly cache: CacheStore | undefined
	) {}

	private options(options: {
		method?: HttpMethod;
		json?: unknown;
		form?: FormData;
	}): RequestOptions {
		return {
			method: options.method,
			json: options.json,
			form: options.form,
			auth: this.auth,
			fetchImpl: this.fetchImpl,
			cache: this.cache
		};
	}

	get<T>(path: string): Promise<T> {
		return requestJson(this.baseUrl, path, this.options({ method: 'GET' }));
	}

	post<T>(path: string, json?: unknown): Promise<T> {
		return requestJson(this.baseUrl, path, this.options({ method: 'POST', json }));
	}

	postForm<T>(path: string, form: FormData): Promise<T> {
		return requestJson(this.baseUrl, path, this.options({ method: 'POST', form }));
	}

	patch<T>(path: string, json: unknown): Promise<T> {
		return requestJson(this.baseUrl, path, this.options({ method: 'PATCH', json }));
	}

	patchForm<T>(path: string, form: FormData): Promise<T> {
		return requestJson(this.baseUrl, path, this.options({ method: 'PATCH', form }));
	}

	delete(path: string): Promise<void> {
		return requestJson(this.baseUrl, path, this.options({ method: 'DELETE' }));
	}
}

/**
 * Builds the multipart body for a create or an update with file fields: a
 * `$content` part with the document JSON plus one part per file, keyed by the
 * normalized field path. `fetch` sets the multipart `Content-Type`.
 */
function fileFieldForm(payload: unknown, files: Record<string, File | Blob>): FormData {
	const form = new FormData();
	form.append('$content', JSON.stringify(payload));
	for (const [fieldPath, file] of Object.entries(files)) {
		form.append(fieldPath, file, filePartName(file));
	}
	return form;
}

/**
 * Fetches one list page and attaches the pager. `next()` closes over the
 * params of its own page, so repeated calls walk `page` forward: an implicit
 * first page is page 1, so the first `next()` asks for page 2.
 */
async function fetchListPage<T>(
	http: Http,
	basePath: string,
	params: ListParams | undefined
): Promise<ListPage<T>> {
	const query = serializeListParams(params ?? {});
	const qs = query.toString();
	const path = qs ? `${basePath}?${qs}` : basePath;
	const res = await http.get<ListResponse<T>>(path);
	return {
		...res,
		next: () => {
			if (!res.meta.more) {
				return Promise.resolve(null);
			}
			// An aggregate answer has no pages. Under `count`, `more` reports a
			// total past the 1000 cap, not a next page; the field modes always
			// answer `more: false`.
			if (params?.aggregate !== undefined) {
				return Promise.resolve(null);
			}
			return fetchListPage<T>(http, basePath, { ...params, page: (params?.page ?? 1) + 1 });
		}
	};
}

class RestCollection<T> implements CollectionHandle<T> {
	constructor(
		private readonly http: Http,
		private readonly basePath: string
	) {}

	list(params?: ListParams): Promise<ListPage<T>> {
		return fetchListPage<T>(this.http, this.basePath, params);
	}

	create(content: T, options?: FilesOptions): Promise<DocumentResponse<T>> {
		if (options?.files !== undefined && Object.keys(options.files).length > 0) {
			return this.http.postForm(this.basePath, fileFieldForm(content, options.files));
		}
		return this.http.post(this.basePath, content);
	}

	doc(id: string): DocumentRef<T> {
		return new RestDocument<T>(this.http, this.basePath, id);
	}
}

class RestDocument<T> implements DocumentRef<T> {
	constructor(
		private readonly http: Http,
		private readonly basePath: string,
		private readonly id: string
	) {}

	private get path(): string {
		return `${this.basePath}/${this.id}`;
	}

	show(): Promise<DocumentResponse<T>> {
		return this.http.get(this.path);
	}

	update(diff: unknown, options?: FilesOptions): Promise<DocumentResponse<T>> {
		if (options?.files !== undefined && Object.keys(options.files).length > 0) {
			return this.http.patchForm(this.path, fileFieldForm(diff, options.files));
		}
		return this.http.patch(this.path, diff);
	}

	delete(): Promise<void> {
		return this.http.delete(this.path);
	}

	action(actionName: string, args?: Record<string, unknown>): Promise<DocumentResponse<T>> {
		return this.http.post(`${this.path}/${actionName}`, args ?? {});
	}

	history(params?: HistoryParams): Promise<HistoryResponse> {
		const query = serializeListParams({
			page: params?.page,
			items: params?.items,
			filters: params?.filters,
			sort: params?.sort
		});
		if (params?.include !== undefined) {
			query.set('include', params.include);
		}
		const qs = query.toString();
		const path = qs ? `${this.path}/history?${qs}` : `${this.path}/history`;
		return this.http.get(path);
	}

	rollback(mutationId: string): Promise<RollbackResponse> {
		return this.http.post(`${this.path}/rollback`, { mutation_id: mutationId });
	}

	restore(): Promise<RollbackResponse> {
		return this.http.post(`${this.path}/restore`, {});
	}

	backrefs(params?: BackrefsParams): Promise<BackrefsResponse> {
		const query = new URLSearchParams();
		if (params?.items !== undefined) {
			query.set('items', String(params.items));
		}
		const qs = query.toString();
		const path = qs ? `${this.path}/backrefs?${qs}` : `${this.path}/backrefs`;
		return this.http.get(path);
	}

	children<C = Record<string, unknown>>(relName: string): CollectionHandle<C> {
		return new RestCollection<C>(this.http, `${this.path}/${relName}`);
	}

	sidecars<C = Record<string, unknown>>(segment: string): CollectionHandle<C> {
		return new RestCollection<C>(this.http, `${this.path}/${segment}`);
	}
}

class RestDomain implements DomainHandle {
	constructor(
		private readonly http: Http,
		private readonly domain: string
	) {}

	doctype<T = Record<string, unknown>>(doctype: string): CollectionHandle<T> {
		return new RestCollection<T>(this.http, `/Api/${this.domain}/${doctype}`);
	}
}

class RestClient implements FacetClient {
	private realtimeHandle: RealtimeHandle | undefined;
	private mePromise: Promise<Me> | undefined;

	constructor(
		private readonly http: Http,
		readonly artifacts: ArtifactHandle,
		private readonly baseUrl: string,
		private readonly auth: TokenProvider | undefined
	) {}

	domain(domain: string): DomainHandle {
		return new RestDomain(this.http, domain);
	}

	realtime(options: RealtimeOptions = {}): RealtimeHandle {
		if (this.realtimeHandle === undefined) {
			this.realtimeHandle = createRealtimeHandle(this.baseUrl, this.auth, options);
		}
		return this.realtimeHandle;
	}

	whoami(): Promise<Me> {
		if (this.mePromise === undefined) {
			this.mePromise = this.http.get<Me>('/Api/iam/me');
		}
		return this.mePromise;
	}

	refreshRights(): Promise<Me> {
		this.mePromise = this.http.get<Me>('/Api/iam/me');
		return this.mePromise;
	}

	async can(action: string, onPath: string): Promise<CanAnswer> {
		const me = await this.whoami();
		return rightsCan(me.permissions, me.scopes, action, onPath);
	}

	async scopes(action: string, onPath: string): Promise<string[]> {
		const me = await this.whoami();
		return rightsScopes(me.permissions, me.scopes, action, onPath);
	}

	async assistant(): Promise<AssistantCapability> {
		const me = await this.whoami();
		return me.assistant;
	}
}

/** `true` means the default in-memory store; a store rides as-is. */
function resolveCache(cache: boolean | CacheStore | undefined): CacheStore | undefined {
	if (cache === true) {
		return memoryCache();
	}
	return cache === false || cache === undefined ? undefined : cache;
}

/**
 * Creates a client for one Facet instance. `facet.domain(d).doctype(t)`
 * returns a collection handle; `doc(id)` on it returns a document ref.
 */
export function createFacetClient(options: FacetClientOptions): FacetClient {
	const cache = resolveCache(options.cache);
	const http = new Http(options.baseUrl, options.auth, options.fetchImpl, cache);
	const artifacts = createArtifactHandle(options.baseUrl, options.auth, options.fetchImpl, cache);
	const client = new RestClient(http, artifacts, options.baseUrl, options.auth);
	return client;
}
