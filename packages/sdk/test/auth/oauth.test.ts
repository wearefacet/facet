// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it, vi } from 'vitest';
import {
	challengeFromVerifier,
	oauthBrowser,
	pkcePair,
	type OAuthBrowserOptions
} from '../../src/auth/oauth.js';
import { memoryFlowStore, memoryTokenStorage } from '../../src/auth/storage.js';
import { AuthError, NotFoundError, UsageError } from '../../src/errors.js';
import { createFacetClient } from '../../src/client.js';

const BASE = 'https://facet.example.com';
const REDIRECT = 'https://app.example.com/callback';
const CLIENT_INFO = `${BASE}/OAuth/client-info?slug=my-app`;
const TOKEN_URL = `${BASE}/OAuth/token`;
const CALLBACK = `${REDIRECT}?code=cd_1&state=st_1`;

function jsonResponse(status: number, body: unknown): Response {
	return {
		ok: status >= 200 && status < 300,
		status,
		statusText: '',
		text: async () => JSON.stringify(body)
	} as unknown as Response;
}

function asFetch(mock: ReturnType<typeof vi.fn>): typeof fetch {
	return mock as unknown as typeof fetch;
}

interface ProviderHarness {
	provider: ReturnType<typeof oauthBrowser>;
	tokens: ReturnType<typeof memoryTokenStorage>;
	flow: ReturnType<typeof memoryFlowStore>;
	waits: number[];
}

function makeProvider(
	fetchImpl: ReturnType<typeof vi.fn>,
	overrides: Partial<OAuthBrowserOptions> = {}
): ProviderHarness {
	const tokens = memoryTokenStorage();
	const flow = memoryFlowStore();
	const waits: number[] = [];
	const provider = oauthBrowser({
		slug: 'my-app',
		redirectUri: REDIRECT,
		baseUrl: BASE,
		tokens,
		flow,
		fetchImpl: asFetch(fetchImpl),
		waitMs: async (ms) => {
			waits.push(ms);
		},
		...overrides
	});
	return { provider, tokens: (overrides.tokens as typeof tokens) ?? tokens, flow, waits };
}

const issuedBody = {
	access_token: 'at_1',
	token_type: 'Bearer',
	expires_in: 900,
	refresh_token: 'rt_1'
};

describe('PKCE', () => {
	it('derives the S256 challenge per the RFC 7636 vector', async () => {
		const challenge = await challengeFromVerifier('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk');
		expect(challenge).toBe('E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
	});

	it('pkcePair yields a 43-char verifier whose challenge matches', async () => {
		const { verifier, challenge } = await pkcePair();
		expect(verifier).toMatch(/^[A-Za-z0-9\-._~]{43}$/);
		expect(challenge).toBe(await challengeFromVerifier(verifier));
		expect(challenge).not.toBe(verifier);
	});
});

describe('signIn', () => {
	it('resolves the client id and navigates to the authorize URL', async () => {
		const fetchImpl = vi
			.fn()
			.mockResolvedValue(
				jsonResponse(200, { slug: 'my-app', client_id: 'cid_1', client_type: 'public' })
			);
		const navigated: string[] = [];
		const { provider, flow } = makeProvider(fetchImpl, {
			navigate: (url) => {
				navigated.push(url);
			}
		});

		await provider.signIn();

		expect(String(fetchImpl.mock.calls[0]?.[0])).toBe(CLIENT_INFO);
		expect(navigated).toHaveLength(1);
		const url = new URL(navigated[0] ?? '');
		expect(url.origin + url.pathname).toBe(`${BASE}/OAuth/authorize`);
		expect(url.searchParams.get('response_type')).toBe('code');
		expect(url.searchParams.get('client_id')).toBe('cid_1');
		expect(url.searchParams.get('redirect_uri')).toBe(REDIRECT);
		const storedFlow = flow.read();
		expect(url.searchParams.get('state')).toBe(storedFlow?.state);
		expect(url.searchParams.get('code_challenge')).toBe(
			await challengeFromVerifier(storedFlow?.verifier ?? '')
		);
		expect(url.searchParams.get('code_challenge_method')).toBe('S256');
		expect(url.searchParams.get('scope')).toBeNull();
		expect(url.searchParams.get('role')).toBeNull();
	});

	it('refuses to navigate without a browser', async () => {
		const fetchImpl = vi.fn().mockResolvedValue(jsonResponse(200, { client_id: 'cid_1' }));
		const { provider } = makeProvider(fetchImpl);
		await expect(provider.signIn()).rejects.toBeInstanceOf(UsageError);
	});

	it('surfaces an unknown slug as NotFoundError', async () => {
		const fetchImpl = vi.fn().mockResolvedValue(jsonResponse(404, { error: 'unknown_client' }));
		const { provider } = makeProvider(fetchImpl);
		await expect(provider.signIn()).rejects.toBeInstanceOf(NotFoundError);
	});
});

describe('handleCallback', () => {
	it('checks the state, exchanges the code, and stores both tokens', async () => {
		const fetchImpl = vi
			.fn()
			.mockResolvedValueOnce(jsonResponse(200, { client_id: 'cid_1' }))
			.mockResolvedValueOnce(jsonResponse(200, issuedBody));
		const { provider, tokens, flow } = makeProvider(fetchImpl);
		flow.write({ state: 'st_1', verifier: 'ver_1' });

		await provider.handleCallback(CALLBACK);

		const { url, init } = callOf(fetchImpl, 1);
		expect(url.origin + url.pathname).toBe(TOKEN_URL);
		expect(init.method).toBe('POST');
		expect((init.headers as Record<string, string>)['content-type']).toBe(
			'application/x-www-form-urlencoded'
		);
		const form = new URLSearchParams(String(init.body));
		expect(form.get('grant_type')).toBe('authorization_code');
		expect(form.get('code')).toBe('cd_1');
		expect(form.get('redirect_uri')).toBe(REDIRECT);
		expect(form.get('client_id')).toBe('cid_1');
		expect(form.get('code_verifier')).toBe('ver_1');
		expect(flow.read()).toBeNull();
		expect(await provider.getToken()).toBe('at_1');
		expect(tokens.read()).toEqual({ accessToken: 'at_1', refreshToken: 'rt_1' });
	});

	it('refuses a state mismatch without an exchange', async () => {
		const fetchImpl = vi.fn();
		const { provider, flow } = makeProvider(fetchImpl);
		flow.write({ state: 'st_1', verifier: 'ver_1' });

		await expect(
			provider.handleCallback(`${REDIRECT}?code=cd_1&state=evil`)
		).rejects.toBeInstanceOf(AuthError);
		expect(flow.read()).toBeNull();
		expect(fetchImpl).not.toHaveBeenCalled();
	});

	it('surfaces the access_denied redirect as AuthError', async () => {
		const fetchImpl = vi.fn();
		const { provider } = makeProvider(fetchImpl);
		await expect(
			provider.handleCallback(`${REDIRECT}?error=access_denied&error_description=no+usable+roles`)
		).rejects.toThrow(/access_denied/);
		expect(fetchImpl).not.toHaveBeenCalled();
	});

	it('refuses when no sign-in is in progress', async () => {
		const { provider } = makeProvider(vi.fn());
		await expect(provider.handleCallback(CALLBACK)).rejects.toBeInstanceOf(AuthError);
	});

	it('maps a token-endpoint failure to AuthError', async () => {
		const fetchImpl = vi
			.fn()
			.mockResolvedValueOnce(jsonResponse(200, { client_id: 'cid_1' }))
			.mockResolvedValueOnce(
				jsonResponse(400, { error: 'invalid_grant', error_description: 'PKCE verification failed' })
			);
		const { provider, tokens, flow } = makeProvider(fetchImpl);
		flow.write({ state: 'st_1', verifier: 'ver_1' });

		await expect(provider.handleCallback(CALLBACK)).rejects.toThrow(/invalid_grant/);
		expect(tokens.read()).toBeNull();
		expect(flow.read()).toBeNull();
	});
});

describe('refresh on 401', () => {
	// The refresh call resolves the client id first (the backend binds a
	// refresh token to the client that exchanged the code), so every mock
	// below must answer the client-info lookup.
	const CLIENT_INFO_RESPONSE = () =>
		jsonResponse(200, { slug: 'my-app', client_id: 'cid_1', client_type: 'public' });

	it('two concurrent 401s produce one refresh call', async () => {
		const tokens = memoryTokenStorage();
		tokens.write({ accessToken: 'stale', refreshToken: 'rt_1' });
		let tokenCalls = 0;
		const fetchImpl = vi.fn(async (url: URL | string, init?: RequestInit) => {
			const u = typeof url === 'string' ? new URL(url) : url;
			if (u.pathname === '/OAuth/client-info') {
				return CLIENT_INFO_RESPONSE();
			}
			if (u.pathname === '/OAuth/token') {
				tokenCalls += 1;
				return jsonResponse(200, { ...issuedBody, access_token: 'fresh', refresh_token: 'rt_2' });
			}
			const authorization = (init?.headers as Record<string, string>)['authorization'];
			if (authorization === 'Bearer stale') {
				return jsonResponse(401, { error: 'token_expired' });
			}
			return jsonResponse(200, { data: [], meta: { count: 0, more: false } });
		});
		const { provider } = makeProvider(fetchImpl, { tokens });
		const companies = createFacetClient({
			baseUrl: BASE,
			auth: provider,
			fetchImpl: asFetch(fetchImpl)
		});

		const [a, b] = await Promise.all([
			companies.domain('crm').doctype('Company').list(),
			companies.domain('crm').doctype('Company').list()
		]);

		expect(a.data).toEqual([]);
		expect(a.meta).toEqual({ count: 0, more: false });
		expect(b.meta).toEqual({ count: 0, more: false });
		expect(tokenCalls).toBe(1);
		// 2 x 401 + 1 client-info + 1 refresh + 2 retries.
		expect(fetchImpl).toHaveBeenCalledTimes(6);
	});

	it('sends the bound client_id on the refresh call', async () => {
		const tokens = memoryTokenStorage();
		tokens.write({ accessToken: 'stale', refreshToken: 'rt_1' });
		const bodies: URLSearchParams[] = [];
		const fetchImpl = vi.fn(async (url: URL | string, init?: RequestInit) => {
			const u = typeof url === 'string' ? new URL(url) : url;
			if (u.pathname === '/OAuth/client-info') {
				return CLIENT_INFO_RESPONSE();
			}
			if (u.pathname === '/OAuth/token') {
				bodies.push(new URLSearchParams(String(init?.body)));
				return jsonResponse(200, { ...issuedBody, access_token: 'at_2', refresh_token: 'rt_2' });
			}
			return jsonResponse(404, { error: 'unexpected' });
		});
		const { provider } = makeProvider(fetchImpl, { tokens });

		await provider.refreshOn401();

		expect(bodies).toHaveLength(1);
		expect(bodies[0]?.get('grant_type')).toBe('refresh_token');
		expect(bodies[0]?.get('refresh_token')).toBe('rt_1');
		expect(bodies[0]?.get('client_id')).toBe('cid_1');
	});

	it('a slow_down answer waits the floor and retries the refresh once', async () => {
		let tokenCalls = 0;
		const fetchImpl = vi.fn(async (url: URL | string) => {
			const u = typeof url === 'string' ? new URL(url) : url;
			if (u.pathname === '/OAuth/client-info') {
				return CLIENT_INFO_RESPONSE();
			}
			if (u.pathname === '/OAuth/token') {
				tokenCalls += 1;
				if (tokenCalls === 1) {
					return jsonResponse(429, { error: 'slow_down', error_description: 'floor' });
				}
				return jsonResponse(200, { ...issuedBody, access_token: 'at_2', refresh_token: 'rt_2' });
			}
			return jsonResponse(404, { error: 'unexpected' });
		});
		const tokens = memoryTokenStorage();
		tokens.write({ accessToken: 'stale', refreshToken: 'rt_1' });
		const { provider, waits } = makeProvider(fetchImpl, { tokens });

		const token = await provider.refreshOn401();

		expect(token).toBe('at_2');
		expect(waits).toEqual([10_000]);
		expect(tokenCalls).toBe(2);
		expect(tokens.read()).toEqual({ accessToken: 'at_2', refreshToken: 'rt_2' });
	});

	it('a second slow_down raises AuthError and keeps the session', async () => {
		let tokenCalls = 0;
		const fetchImpl = vi.fn(async (url: URL | string) => {
			const u = typeof url === 'string' ? new URL(url) : url;
			if (u.pathname === '/OAuth/client-info') {
				return CLIENT_INFO_RESPONSE();
			}
			if (u.pathname === '/OAuth/token') {
				tokenCalls += 1;
				return jsonResponse(429, { error: 'slow_down', error_description: 'floor' });
			}
			return jsonResponse(404, { error: 'unexpected' });
		});
		const tokens = memoryTokenStorage();
		tokens.write({ accessToken: 'stale', refreshToken: 'rt_1' });
		const { provider, waits } = makeProvider(fetchImpl, { tokens });

		await expect(provider.refreshOn401()).rejects.toBeInstanceOf(AuthError);
		expect(waits).toEqual([10_000]);
		expect(tokenCalls).toBe(2);
		expect(tokens.read()?.refreshToken).toBe('rt_1');
	});

	it('an invalid_grant answer raises AuthError and drops the tokens', async () => {
		const fetchImpl = vi.fn(async (url: URL | string) => {
			const u = typeof url === 'string' ? new URL(url) : url;
			if (u.pathname === '/OAuth/client-info') {
				return CLIENT_INFO_RESPONSE();
			}
			return jsonResponse(400, { error: 'invalid_grant', error_description: 'reuse' });
		});
		const tokens = memoryTokenStorage();
		tokens.write({ accessToken: 'stale', refreshToken: 'rt_1' });
		const { provider } = makeProvider(fetchImpl, { tokens });

		await expect(provider.refreshOn401()).rejects.toThrow(/invalid_grant/);
		expect(tokens.read()).toBeNull();
	});

	it('a network failure during refresh raises AuthError', async () => {
		const fetchImpl = vi.fn(async (url: URL | string) => {
			const u = typeof url === 'string' ? new URL(url) : url;
			if (u.pathname === '/OAuth/client-info') {
				return CLIENT_INFO_RESPONSE();
			}
			throw new TypeError('fetch failed');
		});
		const tokens = memoryTokenStorage();
		tokens.write({ accessToken: 'stale', refreshToken: 'rt_1' });
		const { provider } = makeProvider(fetchImpl, { tokens });

		await expect(provider.refreshOn401()).rejects.toThrow(/Could not reach the token endpoint/);
	});
});

describe('getToken', () => {
	// The lazy restore path refreshes, and the refresh resolves the bound
	// client id first — the mock must answer the client-info lookup.
	const CLIENT_INFO_RESPONSE = () =>
		jsonResponse(200, { slug: 'my-app', client_id: 'cid_1', client_type: 'public' });

	it('returns null with no stored tokens', async () => {
		const { provider } = makeProvider(vi.fn());
		expect(await provider.getToken()).toBeNull();
	});

	it('restores lazily from a stored refresh token', async () => {
		let tokenCalls = 0;
		const fetchImpl = vi.fn(async (url: URL | string) => {
			const u = typeof url === 'string' ? new URL(url) : url;
			if (u.pathname === '/OAuth/client-info') {
				return CLIENT_INFO_RESPONSE();
			}
			if (u.pathname === '/OAuth/token') {
				tokenCalls += 1;
				return jsonResponse(200, { ...issuedBody, refresh_token: 'rt_1n' });
			}
			return jsonResponse(404, { error: 'unexpected' });
		});
		const tokens = memoryTokenStorage();
		tokens.write({ accessToken: null, refreshToken: 'rt_1' });
		const { provider } = makeProvider(fetchImpl, { tokens });

		expect(await provider.getToken()).toBe('at_1');
		expect(tokenCalls).toBe(1);
		expect(tokens.read()).toEqual({ accessToken: 'at_1', refreshToken: 'rt_1n' });
	});
});

function callOf(mock: ReturnType<typeof vi.fn>, index: number): { url: URL; init: RequestInit } {
	const call = mock.mock.calls[index];
	if (!call) {
		throw new Error(`fetch was not called a ${index + 1}. time`);
	}
	return { url: call[0] as URL, init: call[1] as RequestInit };
}
