// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { applySetCookies, parseSetCookie, type CookieSetter } from './ssrCookies.js';

/**
 * Unit tests for the SSR Set-Cookie forwarding helper used by `handleFetch`
 * (`hooks.server.ts`).
 *
 * The backend cookie universe (see `IAM::TokenEmitter.set_cookies`) is:
 * - `auth_token` — JWT, `Path=/; Secure; HttpOnly; SameSite=Lax`
 * - `refresh_token` — `session_id.refresh_id` pair, same attributes
 * - logout cleanup — empty value, `Path=/; Expires=<past date>`
 */

const JWT = 'eyJ0eXAiOiJKV1QiLCJhbGciOiJFUzI1NiJ9.eyJzdWIiOiIxMjMifQ.c2lnbmF0dXJl';

/** Collects `event.cookies.set` calls into an array for assertions. */
function recorder(): { calls: Parameters<CookieSetter['cookies']['set']>[]; event: CookieSetter } {
	const calls: Parameters<CookieSetter['cookies']['set']>[] = [];
	const event: CookieSetter = {
		cookies: {
			set: (name, value, options) => calls.push([name, value, options])
		}
	};
	return { calls, event };
}

function responseWithSetCookies(...headers: string[]): Response {
	return new Response(null, {
		headers: headers.map((setCookie) => ['set-cookie', setCookie] as [string, string])
	});
}

describe('parseSetCookie', () => {
	it('parses the auth_token cookie shape (JWT)', () => {
		const parsed = parseSetCookie(`auth_token=${JWT}; path=/; Secure; HttpOnly; SameSite=Lax`);
		expect(parsed).not.toBeNull();
		expect(parsed!.name).toBe('auth_token');
		expect(parsed!.value).toBe(JWT);
		expect(parsed!.path).toBe('/');
		expect(parsed!.secure).toBe(true);
		expect(parsed!.httpOnly).toBe(true);
		expect(parsed!.sameSite).toBe('lax');
	});

	it('parses the refresh_token cookie shape (session_id.refresh_id)', () => {
		const value = 'd3266ecf.39f2131f';
		const parsed = parseSetCookie(`refresh_token=${value}; path=/; HttpOnly; SameSite=Lax`);
		expect(parsed!.value).toBe(value);
	});

	it('parses attribute case-insensitively and keeps unknown attributes harmless', () => {
		const parsed = parseSetCookie('auth_token=abc; PATH=/x; PRIORITY=High');
		expect(parsed!.path).toBe('/x');
	});

	it('parses Max-Age as a number', () => {
		const parsed = parseSetCookie('c=v; Max-Age=1209600; Path=/');
		expect(parsed!.maxAge).toBe(1209600);
	});

	it('parses an Expires date (logout cleanup cookie)', () => {
		const parsed = parseSetCookie('auth_token=; expires=Thu, 01 Jan 2000 00:00:00 GMT; path=/');
		expect(parsed!.expires).not.toBeNaN();
		expect(parsed!.expires!.getUTCFullYear()).toBe(2000);
	});

	it('returns null for an unusable header', () => {
		expect(parseSetCookie('garbage')).toBeNull();
		expect(parseSetCookie('=value')).toBeNull();
		expect(parseSetCookie('')).toBeNull();
	});
});

describe('applySetCookies', () => {
	it('re-issues every Set-Cookie header through event.cookies.set', () => {
		const { calls, event } = recorder();
		const res = responseWithSetCookies(
			`auth_token=${JWT}; path=/; Secure; HttpOnly; SameSite=Lax`,
			'refresh_token=sess.rid; path=/; HttpOnly; SameSite=Lax'
		);

		const applied = applySetCookies(event, res);

		expect(applied).toBe(2);
		expect(calls).toHaveLength(2);
		expect(calls[0]).toEqual([
			'auth_token',
			JWT,
			{ path: '/', domain: undefined, secure: true, httpOnly: true, sameSite: 'lax' }
		]);
		expect(calls[1]).toEqual([
			'refresh_token',
			'sess.rid',
			{ path: '/', domain: undefined, secure: undefined, httpOnly: true, sameSite: 'lax' }
		]);
	});

	it('returns 0 when the response carries no cookies', () => {
		const { calls, event } = recorder();
		expect(applySetCookies(event, new Response(null))).toBe(0);
		expect(calls).toHaveLength(0);
	});

	it('skips unparsable headers instead of throwing', () => {
		const { calls, event } = recorder();
		const res = responseWithSetCookies('garbage', 'ok=v; path=/');
		expect(applySetCookies(event, res)).toBe(1);
		expect(calls).toHaveLength(1);
	});
});
