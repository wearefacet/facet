// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

// B-179 — headless `facet login` must never wait in silence. The authorize
// URL is printed on every run (the opener may exist yet open nothing), the
// flow completes when the user delivers the callback manually, and the
// wait carries a timeout with guidance.

import { afterEach, describe, expect, it, vi } from 'vitest';
import { login, startCallbackServer } from '../src/login.js';
import { writeSession, type StoredSession } from '../src/auth.js';

vi.mock('../src/auth.js', async (importOriginal) => {
	const actual = await importOriginal<typeof import('../src/auth.js')>();
	return { ...actual, writeSession: vi.fn() };
});

const writeSessionMock = vi.mocked(writeSession);

afterEach(() => {
	vi.restoreAllMocks();
	writeSessionMock.mockClear();
	vi.useRealTimers();
});

const INSTANCE = 'https://facet.example.com';
const CLIENT_INFO = {
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

function routedFetch(routes: Record<string, (url: URL) => Response>): typeof vi.fn {
	return vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
		const url = new URL(String(input));
		const route = routes[url.pathname];
		if (!route) throw new Error(`unexpected request: ${url.pathname}`);
		return route(url);
	});
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

describe('login on a headless host (B-179)', () => {
	it('prints the authorize URL and completes when the user delivers the callback by hand', async () => {
		const fetchImpl = routedFetch({
			'/OAuth/client-info': () => jsonResponse(200, CLIENT_INFO),
			'/OAuth/token': () => jsonResponse(200, TOKEN_PAYLOAD),
			'/Api/iam/me': () => jsonResponse(200, ME_PAYLOAD)
		});
		const errors: string[] = [];
		vi.spyOn(console, 'error').mockImplementation((message) => errors.push(message));
		// The opener exists but opens nothing — the headless trap.
		const neverOpens = vi.fn(async () => {});

		const pending = login({
			instanceUrl: INSTANCE,
			fetchImpl: fetchImpl as unknown as typeof fetch,
			openBrowser: neverOpens
		});

		// The URL lands on stderr before the flow can proceed.
		await vi.waitFor(() => {
			expect(errors.join('\n')).toContain('/OAuth/authorize');
		});
		const printedUrl = errors
			.join('\n')
			.split('\n')
			.find((line) => line.startsWith('http'));
		expect(printedUrl).toBeDefined();

		// The user copies the printed URL into a browser elsewhere; the
		// instance redirects to the loopback callback with the state.
		const authorizeUrl = new URL(printedUrl!);
		const redirectUri = authorizeUrl.searchParams.get('redirect_uri')!;
		const state = authorizeUrl.searchParams.get('state')!;
		await fetch(`${redirectUri}?code=auth-code-1&state=${encodeURIComponent(state)}`);

		const session = await pending;
		expect(session.account).toBe('01HACCOUNT');
		expect(neverOpens).toHaveBeenCalledTimes(1);
		expect(writeSessionMock).toHaveBeenCalledWith(
			INSTANCE,
			expect.objectContaining({ access_token: 'at-1' }) as StoredSession
		);
	});

	it('completes even when the opener throws (no browser helper at all)', async () => {
		const fetchImpl = routedFetch({
			'/OAuth/client-info': () => jsonResponse(200, CLIENT_INFO),
			'/OAuth/token': () => jsonResponse(200, TOKEN_PAYLOAD),
			'/Api/iam/me': () => jsonResponse(200, ME_PAYLOAD)
		});
		const errors: string[] = [];
		vi.spyOn(console, 'error').mockImplementation((message) => errors.push(message));
		const brokenOpener = vi.fn(async () => {
			throw new Error('spawn xdg-open ENOENT');
		});

		const pending = login({
			instanceUrl: INSTANCE,
			fetchImpl: fetchImpl as unknown as typeof fetch,
			openBrowser: brokenOpener
		});

		await vi.waitFor(() => {
			expect(errors.join('\n')).toContain('/OAuth/authorize');
		});
		const printedUrl = errors
			.join('\n')
			.split('\n')
			.find((line) => line.startsWith('http'))!;
		const authorizeUrl = new URL(printedUrl);
		const redirectUri = authorizeUrl.searchParams.get('redirect_uri')!;
		const state = authorizeUrl.searchParams.get('state')!;
		await fetch(`${redirectUri}?code=auth-code-1&state=${encodeURIComponent(state)}`);
		await pending;

		expect(errors.join('\n')).toContain('Cannot open a browser automatically');
	});

	it('times out with guidance when no callback arrives', async () => {
		vi.useFakeTimers();
		const server = await startCallbackServer();
		try {
			const pending = server.waitForCallback();
			const rejection = expect(pending).rejects.toThrow(
				/Timed out waiting for the browser sign-in\. Open the authorize URL/
			);
			await vi.advanceTimersByTimeAsync(6 * 60_000);
			await rejection;
		} finally {
			server.close();
		}
	});
});
