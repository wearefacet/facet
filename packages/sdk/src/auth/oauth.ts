// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { AuthError, UsageError } from '../errors.js';
import { requestJson } from '../http.js';
import type { TokenProvider } from './provider.js';
import { browserFlowStore, browserTokenStorage } from './storage.js';
import type { FlowStore, StoredTokens, TokenStorage } from './storage.js';

/**
 * The wait between a `slow_down` answer and the one refresh retry. The
 * backend enforces a 10-second floor between two refreshes of one session.
 */
const SLOW_DOWN_BACKOFF_MS = 10_000;

/** Options for `oauthBrowser`. */
export interface OAuthBrowserOptions {
	/** The app slug registered on the instance. */
	slug: string;
	/** The redirect URI registered on the app. */
	redirectUri: string;
	/**
	 * The instance root. Defaults to the current origin in a browser; a
	 * non-browser runtime must pass one.
	 */
	baseUrl?: string;
	/** Token storage. Default: access in memory, refresh in `localStorage`. */
	tokens?: TokenStorage;
	/** Sign-in state storage. Default: `sessionStorage` with a memory fallback. */
	flow?: FlowStore;
	/** Replacement fetch; tests inject one. */
	fetchImpl?: typeof fetch;
	/** Replacement navigation for `signIn`. Default: a top-level `location.assign`. */
	navigate?: (url: string) => void;
	/** Replacement wait for the `slow_down` back-off; tests inject one. */
	waitMs?: (ms: number) => Promise<void>;
}

/** The browser OAuth helper: a `TokenProvider` plus the sign-in flow. */
export interface OAuthProvider extends TokenProvider {
	/** Resolves the client id, builds the authorize URL, and navigates. */
	signIn(): Promise<void>;
	/** Consumes the redirect back from the consent screen. */
	handleCallback(url: string | URL): Promise<void>;
}

interface TokenEndpointResult {
	status: number;
	body: Record<string, unknown>;
}

/** The pair a successful token response carries. Both halves are set. */
interface TokenPair {
	accessToken: string;
	refreshToken: string;
}

/**
 * Creates the browser PKCE helper. The object attaches the access token to
 * every request and refreshes once on a `401`. `signIn()` navigates to the
 * consent screen; `handleCallback()` consumes the redirect and stores both
 * tokens. The consent screen elects the role — no `role` parameter exists
 * on this surface.
 */
export function oauthBrowser(options: OAuthBrowserOptions): OAuthProvider {
	const storage = options.tokens ?? browserTokenStorage();
	const flowStore = options.flow ?? browserFlowStore();
	const fetchImpl = options.fetchImpl ?? fetch;
	const waitMs = options.waitMs ?? defaultWaitMs;
	const navigate = options.navigate ?? defaultNavigate;

	let accessToken: string | null = null;
	let refreshToken: string | null = null;
	let clientId: string | null = null;
	let refreshInFlight: Promise<string> | null = null;

	const base = (): string => {
		if (options.baseUrl !== undefined && options.baseUrl !== '') {
			return options.baseUrl;
		}
		if (typeof location !== 'undefined' && location.origin !== '') {
			return location.origin;
		}
		throw new UsageError('oauthBrowser needs baseUrl in a non-browser runtime.');
	};

	const resolveClientId = async (): Promise<string> => {
		if (clientId !== null) {
			return clientId;
		}
		const path = `/OAuth/client-info?slug=${encodeURIComponent(options.slug)}`;
		const info = await requestJson<{ client_id?: unknown }>(base(), path, { fetchImpl });
		if (typeof info.client_id !== 'string' || info.client_id === '') {
			throw new AuthError(`The app '${options.slug}' exposes no client_id.`);
		}
		clientId = info.client_id;
		return clientId;
	};

	const tokenCall = async (form: URLSearchParams): Promise<TokenEndpointResult> => {
		let response: Response;
		try {
			response = await fetchImpl(new URL('/OAuth/token', base()), {
				method: 'POST',
				headers: { 'content-type': 'application/x-www-form-urlencoded' },
				body: form.toString()
			});
		} catch (error) {
			throw new AuthError(`Could not reach the token endpoint: ${errorMessage(error)}`);
		}
		const text = await response.text().catch(() => '');
		let body: Record<string, unknown> = {};
		try {
			const parsed: unknown = JSON.parse(text);
			if (typeof parsed === 'object' && parsed !== null) {
				body = parsed as Record<string, unknown>;
			}
		} catch {
			// A non-JSON body keeps the empty record; the status carries the news.
		}
		return { status: response.status, body };
	};

	const readTokenPair = (body: Record<string, unknown>): TokenPair => {
		const access = body['access_token'];
		const refresh = body['refresh_token'];
		if (
			typeof access !== 'string' ||
			access === '' ||
			typeof refresh !== 'string' ||
			refresh === ''
		) {
			throw new AuthError('The token response carries no usable access_token and refresh_token.');
		}
		return { accessToken: access, refreshToken: refresh };
	};

	const failureDetail = (result: TokenEndpointResult): string => {
		const code =
			typeof result.body['error'] === 'string' ? result.body['error'] : `HTTP ${result.status}`;
		const description =
			typeof result.body['error_description'] === 'string'
				? `: ${result.body['error_description']}`
				: '';
		return `Token request failed (${code}${description})`;
	};

	const applyTokens = (pair: TokenPair): void => {
		accessToken = pair.accessToken;
		refreshToken = pair.refreshToken;
		storage.write(pair);
	};

	const refreshWith = async (token: string): Promise<TokenPair> => {
		// The backend binds an app refresh token to the client that exchanged
		// the code. A refresh without the client id answers 401 invalid_grant,
		// so the form always carries the resolved value.
		const form = new URLSearchParams({
			grant_type: 'refresh_token',
			refresh_token: token,
			client_id: await resolveClientId()
		});
		let result = await tokenCall(form);
		if (result.status === 429 && result.body['error'] === 'slow_down') {
			await waitMs(SLOW_DOWN_BACKOFF_MS);
			result = await tokenCall(form);
		}
		if (result.status !== 200) {
			if (result.body['error'] === 'invalid_grant') {
				// The backend revoked the session — the stored tokens are dead.
				accessToken = null;
				refreshToken = null;
				storage.clear();
			}
			throw new AuthError(`${failureDetail(result)}. Sign in again with signIn().`);
		}
		return readTokenPair(result.body);
	};

	// One refresh at a time: concurrent 401s join the in-flight call.
	const ensureFreshToken = (): Promise<string> => {
		if (refreshInFlight !== null) {
			return refreshInFlight;
		}
		const current = refreshToken ?? storage.read()?.refreshToken ?? null;
		if (current === null) {
			return Promise.reject(new AuthError('No refresh token is stored. Sign in with signIn().'));
		}
		refreshToken = current;
		refreshInFlight = refreshWith(current)
			.then((pair) => {
				applyTokens(pair);
				return pair.accessToken;
			})
			.finally(() => {
				refreshInFlight = null;
			});
		return refreshInFlight;
	};

	const getToken = async (): Promise<string | null> => {
		if (accessToken !== null) {
			return accessToken;
		}
		const stored = storage.read();
		if (stored?.accessToken != null) {
			accessToken = stored.accessToken;
			refreshToken = stored.refreshToken ?? refreshToken;
			return accessToken;
		}
		if (stored?.refreshToken != null) {
			// The page reloaded: the access token is gone, the refresh token is
			// not. One refresh serves the request; this is not an eager refresh.
			refreshToken = stored.refreshToken;
			return ensureFreshToken();
		}
		return null;
	};

	const signIn = async (): Promise<void> => {
		const cid = await resolveClientId();
		const { verifier, challenge } = await pkcePair();
		const state = randomUrlSafeToken();
		flowStore.write({ state, verifier });
		const url = new URL('/OAuth/authorize', base());
		url.searchParams.set('response_type', 'code');
		url.searchParams.set('client_id', cid);
		url.searchParams.set('redirect_uri', options.redirectUri);
		url.searchParams.set('state', state);
		url.searchParams.set('code_challenge', challenge);
		url.searchParams.set('code_challenge_method', 'S256');
		navigate(url.toString());
	};

	const handleCallback = async (url: string | URL): Promise<void> => {
		let parsed: URL;
		try {
			parsed = new URL(url);
		} catch {
			throw new UsageError('handleCallback needs an absolute redirect URL.');
		}
		const params = parsed.searchParams;
		const flow = flowStore.read();
		const error = params.get('error');
		if (error !== null) {
			flowStore.clear();
			const description = params.get('error_description');
			throw new AuthError(
				`Authorization was refused (${error}${description === null ? '' : `: ${description}`}).`
			);
		}
		const code = params.get('code');
		const state = params.get('state');
		if (code === null || state === null) {
			flowStore.clear();
			throw new AuthError('The redirect carried no code. Start the sign-in again with signIn().');
		}
		if (flow === null || flow.state !== state) {
			flowStore.clear();
			throw new AuthError(
				'The state parameter does not match the sign-in that started. Start the sign-in again with signIn().'
			);
		}
		flowStore.clear();
		const cid = await resolveClientId();
		const form = new URLSearchParams({
			grant_type: 'authorization_code',
			code,
			redirect_uri: options.redirectUri,
			client_id: cid,
			code_verifier: flow.verifier
		});
		const result = await tokenCall(form);
		if (result.status !== 200) {
			throw new AuthError(`${failureDetail(result)}. Start the sign-in again with signIn().`);
		}
		applyTokens(readTokenPair(result.body));
	};

	return {
		getToken,
		refreshOn401: () => ensureFreshToken(),
		signIn,
		handleCallback
	};
}

/** Builds a fresh PKCE pair: the verifier and its S256 challenge. */
export async function pkcePair(): Promise<{ verifier: string; challenge: string }> {
	const verifier = bytesToBase64Url(randomBytes());
	return { verifier, challenge: await challengeFromVerifier(verifier) };
}

/** Derives the S256 `code_challenge` for one verifier. */
export async function challengeFromVerifier(verifier: string): Promise<string> {
	const encoded = new TextEncoder().encode(verifier);
	const digest = await crypto.subtle.digest('SHA-256', encoded);
	return bytesToBase64Url(new Uint8Array(digest));
}

function randomUrlSafeToken(): string {
	return bytesToBase64Url(randomBytes());
}

function randomBytes(): Uint8Array {
	const bytes = new Uint8Array(32);
	crypto.getRandomValues(bytes);
	return bytes;
}

function bytesToBase64Url(bytes: Uint8Array): string {
	let binary = '';
	for (const byte of bytes) {
		binary += String.fromCharCode(byte);
	}
	return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

const defaultWaitMs = (ms: number): Promise<void> =>
	new Promise((resolve) => {
		setTimeout(resolve, ms);
	});

function defaultNavigate(url: string): void {
	if (typeof window === 'undefined') {
		throw new UsageError('signIn() needs a browser. Pass navigate for a non-browser runtime.');
	}
	window.location.assign(url);
}

function errorMessage(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}
