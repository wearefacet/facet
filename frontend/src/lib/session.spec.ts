// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import { apiFetch, setExpiresAt, getExpiresAt } from './session.svelte.js';

/**
 * Unit tests for `apiFetch`'s token-refresh contract.
 *
 * - 401 recovery: on a 401, refresh is attempted via the injected `fetchFn`,
 *   and on success the original request is retried exactly once.
 * - Pre-emptive refresh: when `expiresAt` is within the threshold, refresh is
 *   called before the actual request.
 * - `attemptRefresh: false` opts out of both.
 *
 * These tests run in Node (no `window`), which exercises the SSR branch:
 * `setExpiresAt` is a no-op, `getExpiresAt` returns null, and the `refreshing`
 * dedup promise is never populated module-wide.
 */

function jsonResponse(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'Content-Type': 'application/json' }
	});
}

const REFRESH_URL = '/Api/iam/refresh';

describe('apiFetch — 401 recovery', () => {
	it('refreshes and retries once on 401, then returns the retried response', async () => {
		let apiCalls = 0;
		let refreshCalls = 0;
		const fetchFn = vi.fn(async (input: string | URL | Request, _init?: RequestInit) => {
			const url = typeof input === 'string' ? input : input.toString();
			if (url === REFRESH_URL) {
				refreshCalls++;
				return jsonResponse({ expires_at: Math.floor(Date.now() / 1000) + 900 });
			}
			if (url === '/Api/foo') {
				apiCalls++;
				if (apiCalls === 1) return jsonResponse({ error: 'expired' }, 401);
				return jsonResponse({ ok: true });
			}
			return jsonResponse({}, 404);
		});

		const res = await apiFetch('/Api/foo', {}, { fetch: fetchFn });
		expect(res.status).toBe(200);
		const body = await res.json();
		expect(body).toEqual({ ok: true });
		expect(refreshCalls).toBe(1);
		expect(apiCalls).toBe(2);
	});

	it('returns a 401 Response when the refresh itself fails (no infinite retry)', async () => {
		let apiCalls = 0;
		const fetchFn = vi.fn(async (input: string | URL | Request, _init?: RequestInit) => {
			const url = typeof input === 'string' ? input : input.toString();
			if (url === REFRESH_URL) return jsonResponse({ error: 'bad' }, 401);
			if (url === '/Api/foo') {
				apiCalls++;
				return jsonResponse({ error: 'expired' }, 401);
			}
			return jsonResponse({}, 404);
		});

		const res = await apiFetch('/Api/foo', {}, { fetch: fetchFn, redirectOnFailure: false });
		expect(res.status).toBe(401);
		expect(apiCalls).toBe(1);
	});

	it('skips 401 recovery entirely when attemptRefresh is false', async () => {
		let apiCalls = 0;
		const fetchFn = vi.fn(async (input: string | URL | Request, _init?: RequestInit) => {
			const url = typeof input === 'string' ? input : input.toString();
			if (url === '/Api/foo') {
				apiCalls++;
				return jsonResponse({ error: 'expired' }, 401);
			}
			return jsonResponse({}, 404);
		});

		const res = await apiFetch(
			'/Api/foo',
			{},
			{ fetch: fetchFn, attemptRefresh: false, redirectOnFailure: false }
		);
		expect(res.status).toBe(401);
		expect(apiCalls).toBe(1);
		expect(fetchFn).toHaveBeenCalledTimes(1);
	});
});

describe('apiFetch — SSR safety (Node environment)', () => {
	beforeEach(() => {
		// Module state should be no-op on the server — but reset defensively.
		setExpiresAt(null);
	});

	afterEach(() => {
		setExpiresAt(null);
	});

	it('setExpiresAt is a no-op on the server (module state stays null)', () => {
		setExpiresAt(Math.floor(Date.now() / 1000) + 60);
		expect(getExpiresAt()).toBeNull();
	});

	it('pre-emptive refresh does not run on the server (expiresAt is null)', async () => {
		// Even if setExpiresAt is called by mistake with a near-expiry value,
		// the getter returns null on the server so pre-emptive refresh is
		// skipped — protecting concurrent users from a shared-state leak.
		setExpiresAt(Math.floor(Date.now() / 1000) - 10);
		expect(getExpiresAt()).toBeNull();

		const fetchFn = vi.fn(async (input: string | URL | Request, _init?: RequestInit) => {
			const url = typeof input === 'string' ? input : input.toString();
			if (url === REFRESH_URL) return jsonResponse({ expires_at: 0 });
			if (url === '/Api/foo') return jsonResponse({ ok: true });
			return jsonResponse({}, 404);
		});

		const res = await apiFetch('/Api/foo', {}, { fetch: fetchFn });
		expect(res.status).toBe(200);
		// No pre-emptive refresh, only the API call.
		expect(fetchFn).toHaveBeenCalledTimes(1);
	});
});

describe('apiFetch — default fetch fallback', () => {
	it('uses the global fetch when opts.fetch is omitted', async () => {
		const original = globalThis.fetch;
		const stub = vi.fn(async () => jsonResponse({ ok: true }));
		globalThis.fetch = stub as unknown as typeof fetch;
		try {
			const res = await apiFetch(
				'/Api/foo',
				{},
				{
					redirectOnFailure: false,
					attemptRefresh: false
				}
			);
			expect(res.status).toBe(200);
			expect(stub).toHaveBeenCalledTimes(1);
		} finally {
			globalThis.fetch = original;
		}
	});
});

describe('apiFetch — CSRF header default', () => {
	function headerOf(init: RequestInit | undefined, name: string): string | null {
		return new Headers(init?.headers).get(name);
	}

	it.each(['POST', 'PATCH', 'PUT', 'DELETE'] as const)(
		'adds X-Requested-With to a %s call when the caller has not set one',
		async (method) => {
			const fetchFn = vi.fn(async (_input: string | URL | Request, init?: RequestInit) => {
				expect(headerOf(init, 'X-Requested-With')).toBe('XMLHttpRequest');
				return jsonResponse({ ok: true });
			});

			const res = await apiFetch('/Api/foo', { method }, { fetch: fetchFn, attemptRefresh: false });
			expect(res.status).toBe(200);
		}
	);

	it('keeps the caller header for a mutating call when one is set', async () => {
		const fetchFn = vi.fn(async (_input: string | URL | Request, init?: RequestInit) => {
			expect(headerOf(init, 'X-Requested-With')).toBe('custom');
			return jsonResponse({ ok: true });
		});

		await apiFetch(
			'/Api/foo',
			{ method: 'POST', headers: { 'X-Requested-With': 'custom' } },
			{ fetch: fetchFn, attemptRefresh: false }
		);
	});

	it('does not add the header to a GET call', async () => {
		const fetchFn = vi.fn(async (_input: string | URL | Request, init?: RequestInit) => {
			expect(headerOf(init, 'X-Requested-With')).toBeNull();
			return jsonResponse({ ok: true });
		});

		await apiFetch('/Api/foo', { fetch: fetchFn, attemptRefresh: false } as RequestInit, {
			fetch: fetchFn,
			attemptRefresh: false
		});
	});

	it('adds the header on the 401-retry of a mutating call', async () => {
		let apiCalls = 0;
		const fetchFn = vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
			const url = typeof input === 'string' ? input : input.toString();
			if (url === REFRESH_URL)
				return jsonResponse({ expires_at: Math.floor(Date.now() / 1000) + 900 });
			if (url === '/Api/foo') {
				apiCalls++;
				expect(headerOf(init, 'X-Requested-With')).toBe('XMLHttpRequest');
				if (apiCalls === 1) return jsonResponse({ error: 'expired' }, 401);
				return jsonResponse({ ok: true });
			}
			return jsonResponse({}, 404);
		});

		const res = await apiFetch('/Api/foo', { method: 'POST' }, { fetch: fetchFn });
		expect(res.status).toBe(200);
		expect(apiCalls).toBe(2);
	});
});
