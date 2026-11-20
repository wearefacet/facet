// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { afterEach, describe, expect, it, vi } from 'vitest';
import {
	buildAuthorizeUrl,
	challengeFor,
	createPkcePair,
	exchangeCode,
	login,
	resolveClientInfo,
	startCallbackServer,
	type CallbackHandle,
	type CallbackResult,
	type ClientInfo
} from '../src/login.js';
import { writeSession, type StoredSession } from '../src/auth.js';

vi.mock('../src/auth.js', async (importOriginal) => {
	const actual = await importOriginal<typeof import('../src/auth.js')>();
	return { ...actual, writeSession: vi.fn() };
});

const writeSessionMock = vi.mocked(writeSession);

afterEach(() => {
	vi.restoreAllMocks();
	writeSessionMock.mockClear();
});

const INSTANCE = 'https://facet.example.com';
const CLIENT_INFO: ClientInfo = {
	slug: 'facet-cli',
	client_id: '01HCLIENT',
	name: 'Facet CLI',
	client_type: 'public'
};

function jsonResponse(status: number, body: unknown): Response {
	return {
		ok: status >= 200 && status < 300,
		status,
		json: async () => body,
		text: async () => JSON.stringify(body)
	} as unknown as Response;
}

function routedFetch(routes: Record<string, (url: URL) => Response>): {
	fetch: ReturnType<typeof vi.fn>;
	calls: { url: URL; init: RequestInit }[];
} {
	const calls: { url: URL; init: RequestInit }[] = [];
	const fetchImpl = vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
		const url = new URL(String(input));
		calls.push({ url, init: init ?? {} });
		const route = routes[url.pathname];
		if (!route) throw new Error(`unexpected request: ${url.pathname}`);
		return route(url);
	});
	return { fetch: fetchImpl, calls };
}

const TOKEN_PAYLOAD = {
	access_token: 'at-1',
	refresh_token: 'rt-1',
	token_type: 'Bearer',
	expires_in: 3600
};

const ME_PAYLOAD = {
	account: { id: '01HACCOUNT', display_name: 'Ada', email: 'ada@example.com' },
	active_role: 'admin'
};

/** A loopback stand-in that replays one prepared callback result. */
function fakeServer(result: CallbackResult | ((authorizeUrl: URL) => CallbackResult)) {
	let resolveCallback: ((value: CallbackResult) => void) | undefined;
	const handle: CallbackHandle = {
		redirectUri: 'http://127.0.0.1:49152/callback',
		waitForCallback: () =>
			new Promise<CallbackResult>((resolve) => {
				resolveCallback = resolve;
			}),
		close: vi.fn()
	};
	return {
		startServer: async () => handle,
		openBrowser: vi.fn(async (url: string) => {
			resolveCallback?.(typeof result === 'function' ? result(new URL(url)) : result);
		})
	};
}

describe('resolveClientInfo', () => {
	it('returns the client metadata on 200', async () => {
		const { fetch: fetchImpl, calls } = routedFetch({
			'/OAuth/client-info': () => jsonResponse(200, CLIENT_INFO)
		});

		const info = await resolveClientInfo(INSTANCE, fetchImpl as unknown as typeof fetch);

		expect(info).toEqual(CLIENT_INFO);
		expect(calls[0]?.url.searchParams.get('slug')).toBe('facet-cli');
	});

	it('raises a login error on the 404 path', async () => {
		const { fetch: fetchImpl } = routedFetch({
			'/OAuth/client-info': () => jsonResponse(404, { error: 'unknown_client' })
		});

		await expect(resolveClientInfo(INSTANCE, fetchImpl as unknown as typeof fetch)).rejects.toThrow(
			/No active "facet-cli" app registration/
		);
	});
});

describe('PKCE', () => {
	it('computes the RFC 7636 appendix B vector', () => {
		const verifier = 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk';
		expect(challengeFor(verifier)).toBe('E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM');
	});

	it('builds a 43-character verifier whose challenge matches', () => {
		const pair = createPkcePair();

		expect(pair.code_verifier).toHaveLength(43);
		expect(pair.code_verifier).toMatch(/^[A-Za-z0-9_-]+$/);
		expect(pair.code_challenge).toBe(challengeFor(pair.code_verifier));
		expect(pair.code_challenge).toMatch(/^[A-Za-z0-9_-]+$/);
	});
});

describe('buildAuthorizeUrl', () => {
	it('carries every authorize parameter', () => {
		const url = new URL(
			buildAuthorizeUrl(INSTANCE, {
				clientId: '01HCLIENT',
				redirectUri: 'http://127.0.0.1:49152/callback',
				codeChallenge: 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM',
				state: 'st-1'
			})
		);

		expect(url.origin).toBe(INSTANCE);
		expect(url.pathname).toBe('/OAuth/authorize');
		expect(url.searchParams.get('response_type')).toBe('code');
		expect(url.searchParams.get('client_id')).toBe('01HCLIENT');
		expect(url.searchParams.get('redirect_uri')).toBe('http://127.0.0.1:49152/callback');
		expect(url.searchParams.get('code_challenge')).toBe(
			'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM'
		);
		expect(url.searchParams.get('code_challenge_method')).toBe('S256');
		expect(url.searchParams.get('state')).toBe('st-1');
	});
});

describe('exchangeCode', () => {
	it('sends the PKCE exchange form body', async () => {
		const { fetch: fetchImpl, calls } = routedFetch({
			'/OAuth/token': () => jsonResponse(200, TOKEN_PAYLOAD)
		});

		const issued = await exchangeCode(
			INSTANCE,
			{
				code: 'auth-code-1',
				redirectUri: 'http://127.0.0.1:49152/callback',
				clientId: '01HCLIENT',
				codeVerifier: 'dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk'
			},
			fetchImpl as unknown as typeof fetch
		);

		expect(issued).toEqual({ access_token: 'at-1', refresh_token: 'rt-1', expires_in: 3600 });
		const call = calls[0];
		expect(call?.url.pathname).toBe('/OAuth/token');
		expect(call?.init.method).toBe('POST');
		const body = new URLSearchParams(String(call?.init.body));
		expect(body.get('grant_type')).toBe('authorization_code');
		expect(body.get('code')).toBe('auth-code-1');
		expect(body.get('redirect_uri')).toBe('http://127.0.0.1:49152/callback');
		expect(body.get('client_id')).toBe('01HCLIENT');
		expect(body.get('code_verifier')).toBe('dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk');
	});

	it('surfaces the OAuth error name on failure', async () => {
		const { fetch: fetchImpl } = routedFetch({
			'/OAuth/token': () =>
				jsonResponse(400, { error: 'invalid_grant', error_description: 'bad code' })
		});

		await expect(
			exchangeCode(
				INSTANCE,
				{
					code: 'c',
					redirectUri: 'http://127.0.0.1:49152/callback',
					clientId: 'x',
					codeVerifier: 'v'
				},
				fetchImpl as unknown as typeof fetch
			)
		).rejects.toThrow(/invalid_grant: bad code/);
	});
});

describe('startCallbackServer', () => {
	it('delivers code and state from a real loopback callback', async () => {
		const server = await startCallbackServer();
		try {
			const port = new URL(server.redirectUri).port;
			const pending = server.waitForCallback();
			await fetch(`http://127.0.0.1:${port}/callback?code=c1&state=s1`);

			await expect(pending).resolves.toEqual({ code: 'c1', state: 's1' });
			expect(new URL(server.redirectUri).pathname).toBe('/callback');
		} finally {
			server.close();
		}
	});

	it('rejects a path that is not the callback', async () => {
		const server = await startCallbackServer();
		try {
			const port = new URL(server.redirectUri).port;
			const response = await fetch(`http://127.0.0.1:${port}/nope`);
			expect(response.status).toBe(404);
		} finally {
			server.close();
		}
	});

	it('stops listening after close', async () => {
		const server = await startCallbackServer();
		const port = new URL(server.redirectUri).port;
		server.close();

		await expect(fetch(`http://127.0.0.1:${port}/callback`)).rejects.toThrow();
	});
});

describe('login', () => {
	it('completes the flow and stores the session through the auth module', async () => {
		const { fetch: fetchImpl, calls } = routedFetch({
			'/OAuth/client-info': () => jsonResponse(200, CLIENT_INFO),
			'/OAuth/token': () => jsonResponse(200, TOKEN_PAYLOAD),
			'/Api/iam/me': () => jsonResponse(200, ME_PAYLOAD)
		});
		const fake = fakeServer((authorizeUrl) => ({
			code: 'auth-code-1',
			state: authorizeUrl.searchParams.get('state') ?? undefined
		}));

		const session = await login({
			instanceUrl: INSTANCE,
			fetchImpl: fetchImpl as unknown as typeof fetch,
			startServer: fake.startServer,
			openBrowser: fake.openBrowser
		});

		expect(fake.openBrowser).toHaveBeenCalledTimes(1);
		const authorizeUrl = new URL(String(fake.openBrowser.mock.calls[0]?.[0]));
		expect(authorizeUrl.searchParams.get('client_id')).toBe('01HCLIENT');
		expect(authorizeUrl.searchParams.get('redirect_uri')).toBe('http://127.0.0.1:49152/callback');

		// client-info, token exchange, then the one validation read.
		expect(calls.map((call) => call.url.pathname)).toEqual([
			'/OAuth/client-info',
			'/OAuth/token',
			'/Api/iam/me'
		]);
		expect((calls[2]?.init.headers as Record<string, string>)['authorization']).toBe('Bearer at-1');

		const stored = writeSessionMock.mock.calls[0]?.[1] as StoredSession;
		expect(stored.access_token).toBe('at-1');
		expect(stored.refresh_token).toBe('rt-1');
		expect(stored.client_id).toBe('01HCLIENT');
		expect(stored.account).toBe('01HACCOUNT');
		expect(stored.role).toBe('admin');
		expect(Date.parse(stored.expires_at)).toBeGreaterThan(Date.now() + 3_000_000);
		expect(writeSessionMock).toHaveBeenCalledWith(INSTANCE, stored);
		expect(session).toEqual(stored);
	});

	it('rejects a callback whose state does not match', async () => {
		const { fetch: fetchImpl, calls } = routedFetch({
			'/OAuth/client-info': () => jsonResponse(200, CLIENT_INFO),
			'/OAuth/token': () => jsonResponse(200, TOKEN_PAYLOAD)
		});
		const fake = fakeServer({ code: 'c1', state: 'tampered-state' });

		await expect(
			login({
				instanceUrl: INSTANCE,
				fetchImpl: fetchImpl as unknown as typeof fetch,
				startServer: fake.startServer,
				openBrowser: fake.openBrowser
			})
		).rejects.toThrow(/state that does not match/);

		// The mismatch aborts before the token endpoint is touched.
		expect(calls.map((call) => call.url.pathname)).toEqual(['/OAuth/client-info']);
		expect(writeSessionMock).not.toHaveBeenCalled();
	});

	it('rejects the flow when the instance reports a denial', async () => {
		const { fetch: fetchImpl } = routedFetch({
			'/OAuth/client-info': () => jsonResponse(200, CLIENT_INFO)
		});
		const fake = fakeServer({ error: 'access_denied' });

		await expect(
			login({
				instanceUrl: INSTANCE,
				fetchImpl: fetchImpl as unknown as typeof fetch,
				startServer: fake.startServer,
				openBrowser: fake.openBrowser
			})
		).rejects.toThrow(/access_denied/);
	});

	it('raises the re-login error when the validation read fails', async () => {
		const { fetch: fetchImpl } = routedFetch({
			'/OAuth/client-info': () => jsonResponse(200, CLIENT_INFO),
			'/OAuth/token': () => jsonResponse(200, TOKEN_PAYLOAD),
			'/Api/iam/me': () => jsonResponse(401, { error: 'unauthorized' })
		});
		const fake = fakeServer((authorizeUrl) => ({
			code: 'c1',
			state: authorizeUrl.searchParams.get('state') ?? undefined
		}));

		await expect(
			login({
				instanceUrl: INSTANCE,
				fetchImpl: fetchImpl as unknown as typeof fetch,
				startServer: fake.startServer,
				openBrowser: fake.openBrowser
			})
		).rejects.toThrow(/failed its validation read/);
		expect(writeSessionMock).not.toHaveBeenCalled();
	});
});
