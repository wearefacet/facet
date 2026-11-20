// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it } from 'vitest';
import {
	clearEnrollContext,
	decodeLoginResponse,
	ENROLL_CONTEXT_KEY,
	isEnrollContextExpired,
	isTokenBody,
	loadEnrollContext,
	saveEnrollContext,
	shouldPromptEnrollment,
	type LoginTokenBody
} from './loginFlow';

const tokenBody: LoginTokenBody = {
	account: {
		id: '01JABC',
		email: 'admin@example.tld',
		display_name: 'Admin',
		mfa_enabled: false,
		mfa_enforcement: 'preferred'
	},
	active_role: 'iam.Roles.Admin',
	available_roles: ['iam.Roles.Admin'],
	expires_at: 1900000000
};

describe('isTokenBody', () => {
	it('accepts a token-emitting response body', () => {
		expect(isTokenBody(tokenBody)).toBe(true);
	});

	it('accepts a body with extra permission fields', () => {
		expect(isTokenBody({ ...tokenBody, permissions: { 'iam.Account': ['read'] } })).toBe(true);
	});

	it('rejects held-login shapes and junk', () => {
		expect(isTokenBody({ mfa: true, challenge_id: 'c1' })).toBe(false);
		expect(isTokenBody({ must_change_password: true, change_token: 't' })).toBe(false);
		expect(isTokenBody({ mfa_enroll_required: true, enroll_token: 'e', secret: 's' })).toBe(false);
		expect(isTokenBody({ ok: true })).toBe(false);
		expect(isTokenBody(null)).toBe(false);
		expect(isTokenBody('nope')).toBe(false);
	});
});

describe('decodeLoginResponse', () => {
	it('maps a token body to the tokens branch', () => {
		const branch = decodeLoginResponse(tokenBody);
		expect(branch).toEqual({ kind: 'tokens', body: tokenBody });
	});

	it('maps the MFA challenge shape', () => {
		const branch = decodeLoginResponse({ mfa: true, challenge_id: 'chal-1', type: 'totp' });
		expect(branch).toEqual({ kind: 'mfa_challenge', challengeId: 'chal-1' });
	});

	it('maps the forced-change shape', () => {
		const branch = decodeLoginResponse({ must_change_password: true, change_token: 'ct-1' });
		expect(branch).toEqual({ kind: 'must_change_password', changeToken: 'ct-1' });
	});

	it('maps the enrollment shape with enforcement mode', () => {
		const branch = decodeLoginResponse({
			mfa_enroll_required: true,
			enroll_token: 'et-1',
			secret: 'JBSWY3DPEHPK3PXP',
			otpauth_uri: 'otpauth://totp/Facet:u%40x?secret=JBSWY3DPEHPK3PXP',
			mfa_enforcement: 'always'
		});
		expect(branch).toEqual({
			kind: 'mfa_enroll',
			enrollToken: 'et-1',
			secret: 'JBSWY3DPEHPK3PXP',
			otpauthUri: 'otpauth://totp/Facet:u%40x?secret=JBSWY3DPEHPK3PXP',
			enforcement: 'always'
		});
	});

	it('defaults the enforcement mode when the backend omits it', () => {
		const branch = decodeLoginResponse({
			mfa_enroll_required: true,
			enroll_token: 'et-1',
			secret: 'S',
			otpauth_uri: 'otpauth://totp/x'
		});
		expect(branch.kind === 'mfa_enroll' && branch.enforcement).toBe('always');
	});

	it('throws on a malformed branch shape instead of guessing tokens', () => {
		expect(() => decodeLoginResponse({ mfa: true })).toThrow();
		expect(() => decodeLoginResponse({ must_change_password: true })).toThrow();
		expect(() => decodeLoginResponse({ mfa_enroll_required: true })).toThrow();
		expect(() => decodeLoginResponse({ unexpected: true })).toThrow();
		expect(() => decodeLoginResponse(null)).toThrow();
		expect(() => decodeLoginResponse(undefined)).toThrow();
	});

	it('checks the branch flags in priority order', () => {
		// A body with a stray token-like field plus a held-login flag must
		// resolve to the held-login branch, never to tokens.
		const branch = decodeLoginResponse({
			must_change_password: true,
			change_token: 'ct',
			expires_at: 1
		});
		expect(branch.kind).toBe('must_change_password');
	});
});

describe('shouldPromptEnrollment', () => {
	it('prompts only for totp + preferred + not enrolled', () => {
		expect(
			shouldPromptEnrollment({ mfa_type: 'totp', mfa_enforcement: 'preferred', mfa_enabled: false })
		).toBe(true);
	});

	it('does not prompt for enrolled accounts', () => {
		expect(
			shouldPromptEnrollment({ mfa_type: 'totp', mfa_enforcement: 'preferred', mfa_enabled: true })
		).toBe(false);
	});

	it('does not prompt when the server runs no MFA factor', () => {
		expect(
			shouldPromptEnrollment({ mfa_type: 'none', mfa_enforcement: 'preferred', mfa_enabled: false })
		).toBe(false);
	});

	it('never prompts under always (the backend holds the login)', () => {
		expect(
			shouldPromptEnrollment({ mfa_type: 'totp', mfa_enforcement: 'always', mfa_enabled: false })
		).toBe(false);
	});

	it('does not prompt when the state is missing', () => {
		expect(
			shouldPromptEnrollment({ mfa_type: '', mfa_enforcement: '', mfa_enabled: false } as never)
		).toBe(false);
	});
});

/** Minimal Storage stand-in — the Vitest `server` project runs in plain Node. */
function memoryStorage(): Storage {
	const map = new Map<string, string>();
	return {
		get length() {
			return map.size;
		},
		clear: () => map.clear(),
		getItem: (key) => (map.has(key) ? (map.get(key) as string) : null),
		key: (index) => Array.from(map.keys())[index] ?? null,
		removeItem: (key) => void map.delete(key),
		setItem: (key, value) => void map.set(key, String(value))
	};
}

const enrollContext = {
	enrollToken: 'et-1',
	secret: 'JBSWY3DPEHPK3PXP',
	otpauthUri: 'otpauth://totp/Facet:u%40x?secret=JBSWY3DPEHPK3PXP'
} as const;

describe('enroll context persistence (F05-07)', () => {
	const SAVE_AT = 1_000_000;

	it('round-trips the context through storage', () => {
		const storage = memoryStorage();
		saveEnrollContext(storage, enrollContext, SAVE_AT);
		expect(loadEnrollContext(storage, SAVE_AT + 1)).toEqual({ ...enrollContext, savedAt: SAVE_AT });
	});

	it('stores only the minimal payload, even when the caller passes more', () => {
		const storage = memoryStorage();
		// A variable, not a literal — the login page passes a decoded branch,
		// which carries extra fields the same way.
		const wide = { ...enrollContext, kind: 'mfa_enroll', enforcement: 'always' };
		saveEnrollContext(storage, wide, SAVE_AT);
		const stored = JSON.parse(storage.getItem(ENROLL_CONTEXT_KEY) as string) as Record<
			string,
			unknown
		>;
		expect(Object.keys(stored).sort()).toEqual(['enrollToken', 'otpauthUri', 'savedAt', 'secret']);
	});

	it('keeps the entry inside the TTL and drops it at the TTL edge', () => {
		const storage = memoryStorage();
		saveEnrollContext(storage, enrollContext, SAVE_AT);
		expect(isEnrollContextExpired(SAVE_AT, SAVE_AT + 299_999)).toBe(false);
		expect(loadEnrollContext(storage, SAVE_AT + 299_999)).not.toBeNull();
		expect(isEnrollContextExpired(SAVE_AT, SAVE_AT + 300_000)).toBe(true);
		expect(loadEnrollContext(storage, SAVE_AT + 300_000)).toBeNull();
		// The expired entry is removed, not left behind.
		expect(storage.getItem(ENROLL_CONTEXT_KEY)).toBeNull();
	});

	it('returns null and clears a corrupt entry', () => {
		const storage = memoryStorage();
		storage.setItem(ENROLL_CONTEXT_KEY, '{not json');
		expect(loadEnrollContext(storage, SAVE_AT)).toBeNull();
		expect(storage.getItem(ENROLL_CONTEXT_KEY)).toBeNull();
	});

	it('returns null and clears a wrongly shaped entry', () => {
		const storage = memoryStorage();
		storage.setItem(
			ENROLL_CONTEXT_KEY,
			JSON.stringify({ enrollToken: 'et', secret: '', otpauthUri: 'otpauth://x', savedAt: SAVE_AT })
		);
		expect(loadEnrollContext(storage, SAVE_AT)).toBeNull();
		expect(storage.getItem(ENROLL_CONTEXT_KEY)).toBeNull();
	});

	it('treats a missing entry as null and leaves storage untouched', () => {
		const storage = memoryStorage();
		expect(loadEnrollContext(storage, SAVE_AT)).toBeNull();
		expect(storage.getItem(ENROLL_CONTEXT_KEY)).toBeNull();
	});

	it('overwrites a previous context — one enroll flow at a time', () => {
		const storage = memoryStorage();
		saveEnrollContext(storage, { ...enrollContext, enrollToken: 'et-old' }, SAVE_AT);
		saveEnrollContext(storage, { ...enrollContext, enrollToken: 'et-new' }, SAVE_AT + 5);
		const loaded = loadEnrollContext(storage, SAVE_AT + 6);
		expect(loaded?.enrollToken).toBe('et-new');
	});

	it('clear removes the entry', () => {
		const storage = memoryStorage();
		saveEnrollContext(storage, enrollContext, SAVE_AT);
		clearEnrollContext(storage);
		expect(storage.getItem(ENROLL_CONTEXT_KEY)).toBeNull();
		expect(loadEnrollContext(storage, SAVE_AT + 1)).toBeNull();
	});

	it('swallows storage failures on save', () => {
		const storage = memoryStorage();
		storage.setItem = () => {
			throw new Error('quota exceeded');
		};
		expect(() => saveEnrollContext(storage, enrollContext, SAVE_AT)).not.toThrow();
	});

	it('treats a failing storage read as no context', () => {
		const storage = memoryStorage();
		storage.getItem = () => {
			throw new Error('storage denied');
		};
		expect(loadEnrollContext(storage, SAVE_AT)).toBeNull();
	});
});
