// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { AuthError, currentToken, refreshSession } from './auth.js';
import { errorMessage } from './util.js';

/** The body type Node's `fetch` accepts. Derived from its own signature so
 * no DOM lib is needed. */
type RequestBody = NonNullable<Parameters<typeof fetch>[1]>['body'];

/** Raised for any failed HTTP exchange with a Facet instance. */
export class ApiError extends Error {
	/** HTTP status, or 0 when the request never reached the server. */
	readonly status: number;
	/** The server's `error` name, or a local fallback name. */
	readonly code: string;
	/** Human-readable detail lines from the server's `details` array. */
	readonly details: string[];

	constructor(message: string, status: number, code: string, details: string[] = []) {
		super(message);
		this.name = 'ApiError';
		this.status = status;
		this.code = code;
		this.details = details;
	}
}

/** System metadata every document response carries. */
export interface DocumentMeta {
	id: string;
	display_name?: string;
	created_at?: string;
	updated_at?: string;
	[key: string]: unknown;
}

/** One document: user-defined content plus system metadata. */
export interface DocumentEnvelope<T = Record<string, unknown>> {
	data: T;
	meta: DocumentMeta;
}

/** A paginated collection of document envelopes. */
export interface ListEnvelope<T = Record<string, unknown>> {
	data: DocumentEnvelope<T>[];
	meta: { count: number; more: boolean };
}

export interface AppContent {
	[key: string]: unknown;
	slug?: string;
	status?: string;
	host?: string;
	active_deployment?: string;
}

export interface DeploymentContent {
	[key: string]: unknown;
	revision?: number;
	note?: string;
	spa?: boolean;
	app_id?: string;
}

/** One `iam.Account` profile, as `/Api/iam/me` answers it. */
export interface MeResponse {
	account: { id: string; display_name?: string; email?: string };
	active_role: string;
}

/** A freshly issued API key. `key` is the raw token, shown exactly once. */
export interface CreatedApiKey {
	id: string;
	key: string;
	display_prefix: string;
	expires_at: string | null;
}

/** The deploy route's response: not a document envelope. */
export interface DeployResult {
	/** The unqualified deployment document id. */
	id: string;
	/** The revision the server assigned to this deployment. */
	revision?: number;
	/** Whether the deployment became the active one. */
	activated: boolean;
	/** How many files the server accepted. */
	files: number;
}

export interface RawRequestOptions {
	method?: 'GET' | 'POST' | 'PATCH';
	/** Bearer token; omitted on public endpoints. */
	token?: string;
	/** A JSON body; serialized and sent as `application/json`. */
	json?: unknown;
	/** A prepared body (multipart); requires `contentType`. */
	body?: RequestBody;
	contentType?: string;
	fetchImpl?: typeof fetch;
}

/**
 * One HTTP exchange with a Facet instance: base URL + path, optional bearer
 * header, JSON body, and error mapping. Every failure raises an `ApiError`
 * whose message carries the server's `error` name and joined details.
 */
export async function requestJson<T>(
	instanceUrl: string,
	path: string,
	options: RawRequestOptions = {}
): Promise<T> {
	const fetchImpl = options.fetchImpl ?? fetch;
	const url = new URL(path, instanceUrl);

	const headers: Record<string, string> = { accept: 'application/json' };
	if (options.token !== undefined) {
		headers['authorization'] = `Bearer ${options.token}`;
	}
	if (options.json !== undefined) {
		headers['content-type'] = 'application/json';
	} else if (options.body !== undefined) {
		if (options.contentType === undefined) {
			throw new ApiError(`A raw body needs a content type for ${url.pathname}`, 0, 'bad_request');
		}
		headers['content-type'] = options.contentType;
	}

	let response: Response;
	try {
		response = await fetchImpl(url, {
			method: options.method ?? 'GET',
			headers,
			body: options.json !== undefined ? JSON.stringify(options.json) : options.body
		});
	} catch (error) {
		throw new ApiError(`Cannot reach ${instanceUrl}: ${errorMessage(error)}`, 0, 'network_error');
	}

	if (!response.ok) {
		throw await apiErrorFrom(response, url);
	}
	if (response.status === 204) {
		return undefined as T;
	}
	const text = await response.text();
	if (text === '') {
		return undefined as T;
	}
	try {
		return JSON.parse(text) as T;
	} catch {
		throw new ApiError(
			`${url.pathname} returned a body that is not JSON.`,
			response.status,
			'bad_response'
		);
	}
}

/** Reads a document error body into an `ApiError` with server details. */
async function apiErrorFrom(response: Response, url: URL): Promise<ApiError> {
	const text = await response.text().catch(() => '');
	let code = response.statusText !== '' ? response.statusText : 'http_error';
	let details: string[] = [];
	try {
		const body = JSON.parse(text) as { error?: unknown; details?: unknown };
		if (typeof body.error === 'string' && body.error !== '') {
			code = body.error;
		}
		details = normalizeDetails(body.details);
	} catch {
		// A non-JSON error body keeps the status-text fallback.
	}
	const joined = [code, ...details].join(': ');
	return new ApiError(
		`HTTP ${response.status} from ${url.pathname}: ${joined}`,
		response.status,
		code,
		details
	);
}

/** Accepts plain strings or `{message}` objects in `details`. */
function normalizeDetails(raw: unknown): string[] {
	if (!Array.isArray(raw)) {
		return [];
	}
	return raw.map((item) => {
		if (typeof item === 'string') {
			return item;
		}
		if (
			typeof item === 'object' &&
			item !== null &&
			typeof (item as { message?: unknown }).message === 'string'
		) {
			return (item as { message: string }).message;
		}
		return JSON.stringify(item);
	});
}

export interface ApiRequestOptions {
	method?: 'GET' | 'POST' | 'PATCH';
	json?: unknown;
	body?: RequestBody;
	contentType?: string;
}

/** The authenticated API surface the commands use. */
export interface FacetApi {
	/** Runs one authenticated request with 401 refresh-and-retry. */
	request<T>(path: string, options?: ApiRequestOptions): Promise<T>;
	/** Reads the caller's profile: account and active role. */
	me(): Promise<MeResponse>;
	/** Issues a user-owned API key pinned to the caller's account and the given role. */
	createApiKey(name: string, role: string): Promise<CreatedApiKey>;
	/** Resolves an app slug to its qualified document id. */
	resolveAppId(slug: string): Promise<string>;
	/** Resolves an app slug, or undefined when no app carries it. */
	findAppId(slug: string): Promise<string | undefined>;
	/** Creates the app registration as a draft (needs `write` on `app.App`). */
	createApp(slug: string): Promise<DocumentEnvelope<AppContent>>;
	/** Reads one `app.App` document by qualified id. */
	readApp(id: string): Promise<DocumentEnvelope<AppContent>>;
	/** Lists the app's deployments, newest revision first. */
	listDeployments(appId: string): Promise<ListEnvelope<DeploymentContent>>;
	/** Points `active_deployment` at the given qualified deployment id. */
	setActiveDeployment(appId: string, deploymentId: string): Promise<DocumentEnvelope<AppContent>>;
	/** Uploads a prepared multipart body as a new deployment. */
	deploy(appId: string, body: RequestBody, contentType: string): Promise<DeployResult>;
}

/**
 * Builds the authenticated API client for one instance. Tokens come from the
 * auth module (`FACET_TOKEN` first, then the stored session). A 401 triggers
 * one refresh and one retry; a 401 after that raises the re-login error.
 */
export function createApi(instanceUrl: string, fetchImpl: typeof fetch = fetch): FacetApi {
	async function request<T>(path: string, options: ApiRequestOptions = {}): Promise<T> {
		const resolved = await currentToken(instanceUrl, fetchImpl);
		try {
			return await requestJson<T>(instanceUrl, path, {
				...options,
				token: resolved.token,
				fetchImpl
			});
		} catch (error) {
			// An env token cannot refresh — its 401 is final.
			if (!(error instanceof ApiError) || error.status !== 401 || resolved.source === 'env') {
				throw error;
			}
			const fresh = await refreshSession(instanceUrl, fetchImpl);
			try {
				return await requestJson<T>(instanceUrl, path, {
					...options,
					token: fresh.access_token,
					fetchImpl
				});
			} catch (retryError) {
				if (retryError instanceof ApiError && retryError.status === 401) {
					throw new AuthError(
						`The session for ${instanceUrl} is no longer valid. ` +
							`Run "pnpx @facetapp/cli login" to sign in again.`
					);
				}
				throw retryError;
			}
		}
	}

	const findAppId = async (slug: string): Promise<string | undefined> => {
		const query = new URLSearchParams({ 'filters[slug__eq]': slug });
		const list = await request<ListEnvelope<AppContent>>(`/Api/app/App?${query.toString()}`);
		return list.data[0]?.meta.id;
	};

	return {
		request,
		me: () => request<MeResponse>('/Api/iam/me'),
		createApiKey: (name, role) =>
			request<CreatedApiKey>('/Api/iam/keys', {
				method: 'POST',
				json: { name, role }
			}),
		findAppId,
		resolveAppId: async (slug) => {
			const found = await findAppId(slug);
			if (found === undefined) {
				throw new ApiError(
					`No app with slug "${slug}" on ${instanceUrl}. Create the app first (write on app.App).`,
					404,
					'unknown_app'
				);
			}
			return found;
		},
		createApp: (slug) =>
			request<DocumentEnvelope<AppContent>>(`/Api/app/App`, {
				method: 'POST',
				// `app.App` requires `name` and has no `display_name` content
				// field. The slug is the default human label; the operator can
				// rename the app later.
				json: { name: slug, slug }
			}),
		readApp: (id) => request<DocumentEnvelope<AppContent>>(`/Api/app/App/${id}`),
		listDeployments: async (appId) => {
			// Reference values are stored qualified, so the filter value is too.
			const query = new URLSearchParams({
				'filters[app_id__eq]': appId,
				sort: '-revision'
			});
			return request<ListEnvelope<DeploymentContent>>(`/Api/app/Deployment?${query.toString()}`);
		},
		setActiveDeployment: async (appId, deploymentId) => {
			return request<DocumentEnvelope<AppContent>>(`/Api/app/App/${appId}`, {
				method: 'PATCH',
				json: { active_deployment: deploymentId }
			});
		},
		deploy: async (appId, body, contentType) => {
			return request<DeployResult>(`/Api/app/${appId}/deploy`, {
				method: 'POST',
				body,
				contentType
			});
		}
	};
}
