// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import {
	chmodSync,
	existsSync,
	mkdirSync,
	mkdtempSync,
	readFileSync,
	rmSync,
	statSync,
	writeFileSync
} from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
	AuthError,
	authFilePath,
	currentToken,
	refreshSession,
	readSession,
	readSessions,
	removeSession,
	writeSession,
	type StoredSession
} from '../src/auth.js';

let configHome: string;

beforeEach(() => {
	configHome = mkdtempSync(path.join(os.tmpdir(), 'facet-cli-auth-'));
	vi.stubEnv('XDG_CONFIG_HOME', configHome);
	vi.stubEnv('FACET_TOKEN', '');
});

afterEach(() => {
	vi.unstubAllEnvs();
	rmSync(configHome, { recursive: true, force: true });
});

const INSTANCE = 'https://facet.example.com';

function session(overrides: Partial<StoredSession> = {}): StoredSession {
	return {
		access_token: 'at-old',
		refresh_token: 'rt-old',
		client_id: '01HCLIENT',
		account: '01J9ACCOUNT',
		role: 'admin',
		expires_at: new Date(Date.now() + 3_600_000).toISOString(),
		...overrides
	};
}

function jsonResponse(status: number, body: unknown): Response {
	return {
		ok: status >= 200 && status < 300,
		status,
		json: async () => body
	} as unknown as Response;
}

describe('auth storage', () => {
	it('round-trips a session through the auth file', () => {
		const value = session();
		writeSession(INSTANCE, value);

		expect(readSession(INSTANCE)).toEqual(value);
	});

	it('stores the auth file with mode 600', () => {
		writeSession(INSTANCE, session());

		const file = authFilePath();
		expect(existsSync(file)).toBe(true);
		expect(statSync(file).mode & 0o777).toBe(0o600);
	});

	it('respects $XDG_CONFIG_HOME', () => {
		writeSession(INSTANCE, session());

		expect(authFilePath()).toBe(path.join(configHome, 'facet', 'auth.json'));
	});

	it('keeps one session per instance URL', () => {
		const other = 'https://staging.facet.example.com';
		writeSession(INSTANCE, session({ access_token: 'at-main' }));
		writeSession(other, session({ access_token: 'at-staging' }));

		expect(readSession(INSTANCE)?.access_token).toBe('at-main');
		expect(readSession(other)?.access_token).toBe('at-staging');

		// Writing the second instance must not clobber the first.
		expect(Object.keys(readSessions())).toHaveLength(2);
	});

	it('normalizes trailing slashes on the instance URL', () => {
		writeSession(`${INSTANCE}/`, session({ access_token: 'at-slash' }));

		expect(readSession(INSTANCE)?.access_token).toBe('at-slash');
	});

	it('returns undefined for an unknown instance', () => {
		expect(readSession('https://other.example.com')).toBeUndefined();
	});

	it('rejects a malformed auth file', () => {
		mkdirSync(path.dirname(authFilePath()), { recursive: true });
		writeFileSync(authFilePath(), '{ nope');

		expect(() => readSessions()).toThrow(AuthError);
		expect(() => readSessions()).toThrow(/not valid JSON/);
	});

	it('rejects a malformed stored session entry', () => {
		writeSession(INSTANCE, session());
		writeFileSync(authFilePath(), JSON.stringify({ [INSTANCE]: { access_token: 'at-only' } }));

		expect(() => readSession(INSTANCE)).toThrow(/malformed/);
	});
});

describe('currentToken', () => {
	it('prefers FACET_TOKEN over the stored session', async () => {
		writeSession(INSTANCE, session());
		vi.stubEnv('FACET_TOKEN', 'fct_service_key');

		const resolved = await currentToken(INSTANCE);

		expect(resolved).toEqual({ token: 'fct_service_key', source: 'env' });
	});

	it('works with FACET_TOKEN alone, with no stored session', async () => {
		vi.stubEnv('FACET_TOKEN', 'fct_service_key');

		const resolved = await currentToken(INSTANCE);

		expect(resolved).toEqual({ token: 'fct_service_key', source: 'env' });
	});

	it('returns the stored access token when the session is fresh', async () => {
		writeSession(INSTANCE, session({ access_token: 'at-fresh' }));
		const fetchImpl = vi.fn();

		const resolved = await currentToken(INSTANCE, fetchImpl as unknown as typeof fetch);

		expect(resolved).toEqual({ token: 'at-fresh', source: 'session' });
		expect(fetchImpl).not.toHaveBeenCalled();
	});

	it('refreshes when the access token is near expiry', async () => {
		writeSession(INSTANCE, session({ expires_at: new Date(Date.now() + 30_000).toISOString() }));
		const fetchImpl = vi.fn().mockResolvedValue(
			jsonResponse(200, {
				access_token: 'at-new',
				refresh_token: 'rt-new',
				token_type: 'Bearer',
				expires_in: 3600
			})
		);

		const resolved = await currentToken(INSTANCE, fetchImpl as unknown as typeof fetch);

		expect(resolved.token).toBe('at-new');
		const stored = readSession(INSTANCE);
		expect(stored?.access_token).toBe('at-new');
		expect(Date.parse(stored?.expires_at ?? '')).toBeGreaterThan(Date.now() + 3_000_000);
	});

	it('fails with a login hint when nothing is stored', async () => {
		await expect(currentToken(INSTANCE)).rejects.toThrow(/login/);
	});
});

describe('refreshSession', () => {
	it('posts the refresh grant and stores the rotated tokens', async () => {
		writeSession(INSTANCE, session());
		const fetchImpl = vi.fn().mockResolvedValue(
			jsonResponse(200, {
				access_token: 'at-new',
				refresh_token: 'rt-new',
				token_type: 'Bearer',
				expires_in: 1800
			})
		);

		const fresh = await refreshSession(INSTANCE, fetchImpl as unknown as typeof fetch);

		const [url, init] = fetchImpl.mock.calls[0] as unknown as [URL, RequestInit];
		expect(String(url)).toBe('https://facet.example.com/OAuth/token');
		expect(init.method).toBe('POST');
		expect(String(init.body)).toContain('grant_type=refresh_token');
		expect(String(init.body)).toContain('refresh_token=rt-old');
		// The refresh is bound to the client that exchanged the code.
		expect(String(init.body)).toContain('client_id=01HCLIENT');

		expect(fresh.access_token).toBe('at-new');
		expect(fresh.refresh_token).toBe('rt-new');
		// Account, role, and client id survive the rotation untouched.
		expect(fresh.account).toBe('01J9ACCOUNT');
		expect(fresh.role).toBe('admin');
		expect(fresh.client_id).toBe('01HCLIENT');

		const stored = readSession(INSTANCE);
		expect(stored?.refresh_token).toBe('rt-new');
	});

	it('raises the re-login error on a rejected refresh and stores no broken session', async () => {
		const before = session();
		writeSession(INSTANCE, before);
		const fetchImpl = vi
			.fn()
			.mockResolvedValue(
				jsonResponse(400, { error: 'invalid_grant', error_description: 'Session expired' })
			);

		await expect(refreshSession(INSTANCE, fetchImpl as unknown as typeof fetch)).rejects.toThrow(
			/login/
		);

		// The file still holds the original session — nothing partial got written.
		expect(readSession(INSTANCE)).toEqual(before);
	});

	it('raises the re-login error when the token response is unusable', async () => {
		writeSession(INSTANCE, session());
		const fetchImpl = vi.fn().mockResolvedValue(jsonResponse(200, { access_token: 'at-only' }));

		await expect(refreshSession(INSTANCE, fetchImpl as unknown as typeof fetch)).rejects.toThrow(
			/login/
		);
		expect(readSession(INSTANCE)?.refresh_token).toBe('rt-old');
	});

	it('raises the re-login error on a network failure', async () => {
		writeSession(INSTANCE, session());
		const fetchImpl = vi.fn().mockRejectedValue(new TypeError('fetch failed'));

		await expect(refreshSession(INSTANCE, fetchImpl as unknown as typeof fetch)).rejects.toThrow(
			/login/
		);
	});

	it('reports the OAuth error name from the failed response', async () => {
		writeSession(INSTANCE, session());
		const fetchImpl = vi
			.fn()
			.mockResolvedValue(
				jsonResponse(400, { error: 'invalid_grant', error_description: 'Session expired' })
			);

		const error = await refreshSession(INSTANCE, fetchImpl as unknown as typeof fetch).catch(
			(caught: unknown) => caught
		);

		expect(error).toBeInstanceOf(AuthError);
		expect((error as Error).message).toContain('invalid_grant');
	});

	it('raises the login hint when no session is stored', async () => {
		const fetchImpl = vi.fn();

		await expect(refreshSession(INSTANCE, fetchImpl as unknown as typeof fetch)).rejects.toThrow(
			/No stored session/
		);
		expect(fetchImpl).not.toHaveBeenCalled();
	});
});

describe('auth file readability', () => {
	it('reads sessions written by another mode and still rewrites at 600', () => {
		writeSession(INSTANCE, session());
		chmodSync(authFilePath(), 0o644);
		expect(statSync(authFilePath()).mode & 0o777).toBe(0o644);

		writeSession(INSTANCE, session({ access_token: 'at-again' }));

		expect(statSync(authFilePath()).mode & 0o777).toBe(0o600);
		expect(readFileSync(authFilePath(), 'utf8')).toContain('at-again');
	});
});

describe('removeSession', () => {
	it('removes one instance and keeps the others', () => {
		writeSession(INSTANCE, session());
		writeSession('https://other.example.com', session({ access_token: 'other' }));

		expect(removeSession(INSTANCE)).toBe(true);

		expect(readSession(INSTANCE)).toBeUndefined();
		expect(readSession('https://other.example.com')?.access_token).toBe('other');
		expect(statSync(authFilePath()).mode & 0o777).toBe(0o600);
	});

	it('reports false when nothing is stored', () => {
		expect(removeSession('https://never-logged-in.example.com')).toBe(false);
	});
});
