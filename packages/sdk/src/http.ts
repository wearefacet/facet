// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import {
	ApiError,
	AuthError,
	DeletedError,
	NetworkError,
	NotFoundError,
	normalizeDetails
} from './errors.js';
import type { TokenProvider } from './auth/provider.js';
import { cacheKey } from './cache.js';
import type { CacheStore } from './cache.js';

/** The HTTP verbs the Facet API uses. */
export type HttpMethod = 'GET' | 'POST' | 'PATCH' | 'DELETE';

/** Options for one request. */
export interface RequestOptions {
	/** HTTP verb; `GET` when omitted. */
	method?: HttpMethod;
	/** A JSON body; serialized and sent as `application/json`. */
	json?: unknown;
	/** A multipart body. `fetch` sets the `Content-Type` with its boundary. */
	form?: FormData;
	/** Credential source. Omit it for a public endpoint. */
	auth?: TokenProvider;
	/** Replacement fetch; tests inject one. */
	fetchImpl?: typeof fetch;
	/** ETag store for conditional GETs. Only a GET reads or writes it. */
	cache?: CacheStore;
}

/**
 * One HTTP exchange with a Facet instance: base URL plus path, optional bearer
 * header, JSON body, and typed error mapping. A non-2xx answer maps to an
 * `ApiError` subclass. A fetch throw maps to `NetworkError`.
 */
export async function requestJson<T>(
	baseUrl: string,
	path: string,
	options: RequestOptions = {}
): Promise<T> {
	const fetchImpl = options.fetchImpl ?? fetch;
	const url = new URL(path, baseUrl);
	const method = options.method ?? 'GET';
	// Only a GET revalidates. Mutating verbs never send `If-None-Match` and
	// never read or write the store.
	const store = method === 'GET' ? options.cache : undefined;
	const key = cacheKey(method, url);
	const cached = store === undefined ? undefined : store.get(key);

	let headers: Record<string, string> = { accept: 'application/json' };
	if (options.auth !== undefined) {
		const token = await options.auth.getToken();
		if (!token) {
			throw new AuthError(
				'No credential is available for this request. Provide a token provider that returns a bearer token.'
			);
		}
		headers['authorization'] = `Bearer ${token}`;
	}
	if (options.json !== undefined) {
		headers['content-type'] = 'application/json';
	}
	if (cached !== undefined) {
		headers['if-none-match'] = cached.validator;
	}

	// A multipart body rides as-is; `fetch` adds the boundary header.
	const body: BodyInit | undefined =
		options.form !== undefined
			? options.form
			: options.json !== undefined
				? JSON.stringify(options.json)
				: undefined;

	let response = await exchange(fetchImpl, baseUrl, url, method, headers, body, options.auth);

	// One 401 retry: a refresh-capable provider hands over a fresh token and
	// the request rides again with new headers. A failed refresh raises
	// `AuthError` inside the provider and surfaces as-is.
	const auth = options.auth;
	if (response.status === 401 && auth !== undefined && auth.refreshOn401 !== undefined) {
		const fresh = await auth.refreshOn401();
		if (fresh !== '') {
			headers = { ...headers, authorization: `Bearer ${fresh}` };
			response = await exchange(fetchImpl, baseUrl, url, method, headers, body, auth);
		}
	}

	// Any 304 counts as a hit; the client does not check validator strength.
	if (response.status === 304 && cached !== undefined) {
		return cached.envelope as T;
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
	let parsed: unknown;
	try {
		parsed = JSON.parse(text);
	} catch {
		throw new ApiError(`${url.pathname} returned a body that is not JSON.`, response.status);
	}
	if (store !== undefined) {
		const etag = response.headers.get('etag');
		if (etag !== null && etag !== '') {
			store.set(key, { validator: etag, envelope: parsed });
		} else {
			// A 200 without a validator would leave a stale entry behind.
			store.delete(key);
		}
	}
	return parsed as T;
}

/**
 * Sends one exchange and retries once on a `401` through a refresh-capable
 * provider. Shared by the JSON and byte paths.
 */
async function exchange(
	fetchImpl: typeof fetch,
	baseUrl: string,
	url: URL,
	method: HttpMethod,
	headers: Record<string, string>,
	body: BodyInit | undefined,
	auth: TokenProvider | undefined
): Promise<Response> {
	const send = async (): Promise<Response> => {
		try {
			return await fetchImpl(url, { method, headers, body });
		} catch (error) {
			throw new NetworkError(`Cannot reach ${baseUrl}: ${errorMessage(error)}`);
		}
	};
	let response = await send();
	if (response.status === 401 && auth !== undefined && auth.refreshOn401 !== undefined) {
		const fresh = await auth.refreshOn401();
		if (fresh !== '') {
			headers = { ...headers, authorization: `Bearer ${fresh}` };
			response = await send();
		}
	}
	return response;
}

/** The redirect statuses a byte download follows by hand. */
const REDIRECT_STATUSES = new Set([301, 302, 303, 307, 308]);

/**
 * Fetches one resource as raw bytes: bearer header, typed error mapping, and
 * a followed redirect. The download gateway answers `302` with a signed serve
 * URL; `fetch` follows it by default, and a redirect that survives — a manual
 * or mocked transport — is followed once here. The credential never rides the
 * redirect target: the signed URL authorizes itself.
 */
export async function requestBytes(
	baseUrl: string,
	path: string,
	options: RequestOptions = {}
): Promise<ArrayBuffer> {
	const fetchImpl = options.fetchImpl ?? fetch;
	const url = new URL(path, baseUrl);
	const headers: Record<string, string> = {};
	if (options.auth !== undefined) {
		const token = await options.auth.getToken();
		if (!token) {
			throw new AuthError(
				'No credential is available for this request. Provide a token provider that returns a bearer token.'
			);
		}
		headers['authorization'] = `Bearer ${token}`;
	}
	const response = await exchange(
		fetchImpl,
		baseUrl,
		url,
		options.method ?? 'GET',
		headers,
		undefined,
		options.auth
	);
	if (REDIRECT_STATUSES.has(response.status)) {
		const location = response.headers.get('location');
		if (location !== null && location !== '') {
			const target = new URL(location, url);
			const followed = await exchange(fetchImpl, baseUrl, target, 'GET', {}, undefined, undefined);
			if (!followed.ok) {
				throw await apiErrorFrom(followed, target);
			}
			return followed.arrayBuffer();
		}
	}
	if (!response.ok) {
		throw await apiErrorFrom(response, url);
	}
	return response.arrayBuffer();
}

/** Reads an error body into a typed `ApiError`. */
async function apiErrorFrom(response: Response, url: URL): Promise<ApiError> {
	const text = await response.text().catch(() => '');
	const meta: Record<string, unknown> = {};
	let code = response.statusText || 'http_error';
	let rawDetails: unknown;
	try {
		const body = JSON.parse(text) as Record<string, unknown>;
		if (typeof body['error'] === 'string' && body['error'] !== '') {
			code = body['error'];
		}
		rawDetails = body['details'];
		for (const [key, value] of Object.entries(body)) {
			if (key !== 'error' && key !== 'details') {
				meta[key] = value;
			}
		}
	} catch {
		// A non-JSON error body keeps the status-text fallback.
	}
	const details = normalizeDetails(rawDetails);
	const joined = [code, ...details.map((item) => item.message)].join(': ');
	const message = `HTTP ${response.status} from ${url.pathname}: ${joined}`;
	if (response.status === 404) {
		return new NotFoundError(message, details, meta);
	}
	if (response.status === 410) {
		return new DeletedError(message, meta);
	}
	return new ApiError(message, response.status, details, meta);
}

function errorMessage(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}
