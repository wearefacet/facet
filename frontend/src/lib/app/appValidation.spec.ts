// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import {
	toSlug,
	validateOrigin,
	validateRedirectUri,
	redirectOriginAllowed,
	deriveSignInAddress,
	discoveryPath,
	validateHostname,
	validateDeployPath,
	buildClientSnippet,
	buildCurlSnippet,
	grantsToScopes
} from './appValidation.js';
import type { AppContent, AppGrant } from './appTypes.js';
import { levelToActions } from './appGrantsMapping.js';

describe('appValidation — toSlug', () => {
	it('lowercases and hyphenates a display name', () => {
		expect(toSlug('CRM Portal')).toBe('crm-portal');
		expect(toSlug('My Cool App')).toBe('my-cool-app');
	});

	it('strips non-alphanumeric characters', () => {
		expect(toSlug('CRM Portal 2.0!')).toBe('crm-portal-2-0');
	});

	it('collapses consecutive separators', () => {
		expect(toSlug('A   B___C')).toBe('a-b-c');
	});

	it('strips leading and trailing hyphens', () => {
		expect(toSlug('--hello--')).toBe('hello');
	});

	it('caps at 64 characters', () => {
		const long = 'a'.repeat(200);
		expect(toSlug(long).length).toBe(64);
	});

	it('returns empty for an all-non-alphanumeric input', () => {
		expect(toSlug('!!!')).toBe('');
		expect(toSlug('')).toBe('');
	});
});

describe('appValidation — validateOrigin', () => {
	it('accepts a bare https origin', () => {
		expect(validateOrigin('https://crm.acme.com')).toBeNull();
	});

	it('accepts an origin with a port', () => {
		expect(validateOrigin('http://localhost:5173')).toBeNull();
	});

	it('rejects a non-URL', () => {
		expect(validateOrigin('not a url')).not.toBeNull();
	});

	it('rejects a non-http(s) scheme', () => {
		expect(validateOrigin('ftp://example.com')).not.toBeNull();
	});

	it('rejects an origin with a path', () => {
		expect(validateOrigin('https://crm.acme.com/path')).not.toBeNull();
	});

	it('rejects an origin with a query or fragment', () => {
		expect(validateOrigin('https://crm.acme.com?q=1')).not.toBeNull();
		expect(validateOrigin('https://crm.acme.com#frag')).not.toBeNull();
	});

	it('rejects an empty value', () => {
		expect(validateOrigin('')).not.toBeNull();
		expect(validateOrigin('   ')).not.toBeNull();
	});
});

describe('appValidation — validateRedirectUri', () => {
	it('accepts an absolute https URI', () => {
		expect(validateRedirectUri('https://crm.acme.com/oauth/callback')).toBeNull();
	});

	it('accepts http on localhost for development', () => {
		expect(validateRedirectUri('http://localhost:5173/auth/cb')).toBeNull();
		expect(validateRedirectUri('http://127.0.0.1:5173/auth/cb')).toBeNull();
		expect(validateRedirectUri('http://[::1]:5173/auth/cb')).toBeNull();
	});

	it('accepts the loopback wildcard port', () => {
		expect(validateRedirectUri('http://localhost:*')).toBeNull();
		expect(validateRedirectUri('http://127.0.0.1:*')).toBeNull();
		expect(validateRedirectUri('http://[::1]:*')).toBeNull();
		expect(validateRedirectUri('http://localhost:*/auth/cb')).toBeNull();
	});

	it('rejects a wildcard on a non-loopback host or outside the port', () => {
		expect(validateRedirectUri('https://crm.acme.com:*')).not.toBeNull();
		expect(validateRedirectUri('https://*.crm.acme.com/cb')).not.toBeNull();
		expect(validateRedirectUri('https://localhost:*')).not.toBeNull();
	});

	it('rejects http on a non-loopback host', () => {
		expect(validateRedirectUri('http://crm.acme.com/oauth/callback')).not.toBeNull();
	});

	it('rejects a fragment', () => {
		expect(validateRedirectUri('https://crm.acme.com/cb#frag')).not.toBeNull();
	});

	it('rejects a non-URL', () => {
		expect(validateRedirectUri('not a url')).not.toBeNull();
	});

	it('rejects an empty value', () => {
		expect(validateRedirectUri('')).not.toBeNull();
	});
});

describe('appValidation — redirectOriginAllowed', () => {
	const origins = ['https://crm.acme.com', 'http://localhost:5173'];

	it('returns true when the redirect origin is in allowed_origins', () => {
		expect(redirectOriginAllowed('https://crm.acme.com/oauth/callback', origins)).toBe(true);
	});

	it('matches localhost dev origins', () => {
		expect(redirectOriginAllowed('http://localhost:5173/auth/cb', origins)).toBe(true);
	});

	it('returns false when no origin matches', () => {
		expect(redirectOriginAllowed('https://evil.example.com/cb', origins)).toBe(false);
	});

	it('is case-insensitive on the host and tolerates trailing slashes', () => {
		expect(
			redirectOriginAllowed('https://CRM.ACME.COM/oauth/callback', ['https://crm.acme.com/'])
		).toBe(true);
	});

	it('returns false for a malformed redirect URI', () => {
		expect(redirectOriginAllowed('not a url', origins)).toBe(false);
	});

	it('returns false for the loopback wildcard form (no single origin)', () => {
		expect(redirectOriginAllowed('http://localhost:*', origins)).toBe(false);
	});
});

describe('appValidation — deriveSignInAddress / discoveryPath', () => {
	it('derives the sign-in deep link from issuer base and client id', () => {
		// The endpoint matches discovery: `${issuer}/OAuth/authorize`
		// (`src/oauth/discovery.cr`), addressed by the app's client id —
		// no per-app sign-in route exists (B-200).
		expect(deriveSignInAddress('https://acme.facet.app', 'app_7fk29xqm3vbn')).toBe(
			'https://acme.facet.app/OAuth/authorize?client_id=app_7fk29xqm3vbn'
		);
	});

	it('strips a trailing slash from the issuer base', () => {
		expect(deriveSignInAddress('https://acme.facet.app/', 'app_x')).toBe(
			'https://acme.facet.app/OAuth/authorize?client_id=app_x'
		);
		expect(deriveSignInAddress('https://acme.facet.app//', 'app_x')).toBe(
			'https://acme.facet.app/OAuth/authorize?client_id=app_x'
		);
	});

	it('percent-encodes the client id into the query', () => {
		expect(deriveSignInAddress('https://acme.facet.app', 'a"b')).toBe(
			'https://acme.facet.app/OAuth/authorize?client_id=a%22b'
		);
	});

	it('returns the RFC 8414 discovery path', () => {
		expect(discoveryPath()).toBe('/.well-known/oauth-authorization-server');
	});
});

describe('appValidation — grantsToScopes', () => {
	it('converts a grants array into flat domain.doctype:action strings', () => {
		// Action names are canonicalised: the `write` alias expands to its
		// create/update pair, so the snippet names the actions the runtime
		// enforcer checks.
		const grants: AppGrant[] = [
			{ target: 'crm.Company', actions: levelToActions('write') },
			{ target: 'crm.Contact', actions: levelToActions('read') }
		];
		expect(grantsToScopes(grants)).toEqual([
			'crm.company:create',
			'crm.company:read',
			'crm.company:update',
			'crm.contact:read'
		]);
	});

	it('lowercases the domain and doctype', () => {
		const grants: AppGrant[] = [
			{ target: 'CRM.Company', actions: [{ name: 'read', required: false }] }
		];
		expect(grantsToScopes(grants)).toEqual(['crm.company:read']);
	});

	it('expands a domain wildcard into per-action scope strings', () => {
		const grants: AppGrant[] = [{ target: 'crm.*', actions: [{ name: 'read', required: false }] }];
		expect(grantsToScopes(grants)).toEqual(['crm.*:read']);
	});

	it('de-duplicates scopes', () => {
		const grants: AppGrant[] = [
			{
				target: 'crm.Company',
				actions: [
					{ name: 'read', required: false },
					{ name: 'read', required: true }
				]
			}
		];
		expect(grantsToScopes(grants)).toEqual(['crm.company:read']);
	});

	it('fails safe on a non-array grants value', () => {
		expect(grantsToScopes(null as unknown as AppGrant[])).toEqual([]);
	});

	it('ignores a malformed target without a dot', () => {
		const grants: AppGrant[] = [
			{ target: 'Company', actions: [{ name: 'read', required: false }] }
		];
		expect(grantsToScopes(grants)).toEqual([]);
	});
});

describe('appValidation — buildCurlSnippet', () => {
	it('builds a curl example that lists a doctype collection with the bearer key', () => {
		const snippet = buildCurlSnippet('fct_ABCDEFGHJKLMNOPQRSTUVWXYZ');
		expect(snippet).toContain("# List contacts as the app's service identity");
		expect(snippet).toContain('curl "$FACET_URL/Api/crm/Contact"');
		expect(snippet).toContain('-H "Authorization: Bearer fct_ABCDEFGHJKLMNOPQRSTUVWXYZ"');
	});

	it('embeds the key verbatim', () => {
		expect(buildCurlSnippet('fct_k').endsWith('Bearer fct_k"')).toBe(true);
	});

	it('keeps the header on its own continuation line', () => {
		const snippet = buildCurlSnippet('fct_k');
		expect(snippet.split('\n')).toHaveLength(3);
		expect(snippet.split('\n')[1].endsWith('\\')).toBe(true);
	});
});

describe('appValidation — buildClientSnippet', () => {
	it('builds a syntactically valid createClient snippet from an app', () => {
		const app: AppContent = {
			slug: 'crm-portal',
			name: 'CRM Portal',
			client_id: 'app_7fk29xqm3vbn',
			redirect_uris: ['https://crm.acme.com/oauth/callback'],
			grants: [
				{ target: 'crm.Company', actions: levelToActions('write') },
				{ target: 'crm.Contact', actions: levelToActions('read') }
			]
		};
		const snippet = buildClientSnippet(app, 'https://acme.facet.app');
		expect(snippet).toContain('const facet = createClient({');
		expect(snippet).toContain('issuer: "https://acme.facet.app"');
		expect(snippet).toContain('clientId: "app_7fk29xqm3vbn"');
		expect(snippet).toContain('redirectUri: "https://crm.acme.com/oauth/callback"');
		// The endpoint matches discovery: `${issuer}/OAuth/authorize` with the
		// app's client id (B-200 — no per-app sign-in route exists).
		expect(snippet).toContain(
			'authorizationEndpoint: "https://acme.facet.app/OAuth/authorize?client_id=app_7fk29xqm3vbn"'
		);
		expect(snippet).toContain(
			'scopes: ["crm.company:create", "crm.company:read", "crm.company:update", "crm.contact:read"]'
		);
	});

	it('omits the redirectUri line when the app has no redirect URIs', () => {
		const app: AppContent = {
			slug: 'svc',
			name: 'Svc',
			client_id: 'app_x',
			grants: []
		};
		const snippet = buildClientSnippet(app, 'https://acme.facet.app');
		expect(snippet).not.toContain('redirectUri');
		expect(snippet).toContain('scopes: []');
	});

	it('escapes and encodes double quotes in values', () => {
		const app: AppContent = {
			slug: 'a"b',
			name: 'A',
			client_id: 'a"b',
			grants: []
		};
		const snippet = buildClientSnippet(app, 'https://acme.facet.app');
		// The client-id line escapes the quote for the emitted code; the
		// endpoint line percent-encodes it for the URL.
		expect(snippet).toContain('clientId: "a\\"b"');
		expect(snippet).toContain(
			'authorizationEndpoint: "https://acme.facet.app/OAuth/authorize?client_id=a%22b"'
		);
	});
});

describe('appValidation — validateHostname (deployment serving)', () => {
	it('accepts a plain hostname', () => {
		expect(validateHostname('hr.app.company.tld')).toBeNull();
		expect(validateHostname('localhost')).toBeNull();
	});

	it('rejects a host that carries a port (B-211)', () => {
		// The deployment target supplies the port at serve time; the stored
		// host is bare.
		expect(validateHostname('hr.app.company.tld:8443')).toMatch(/lowercase hostname/);
		expect(validateHostname('localhost:3000')).toMatch(/lowercase hostname/);
	});

	it('rejects scheme, path, wildcard, uppercase, and bad label shapes', () => {
		const bad = [
			'https://hr.app.example.com',
			'hr.app.example.com/path',
			'*.app.example.com',
			'HR.App.Example.COM',
			'-leading.example.com',
			'trailing-.example.com',
			'hr app.example.com',
			'hr_app.example.com'
		];
		for (const value of bad) {
			expect(validateHostname(value), value).toMatch(/lowercase hostname/);
		}
	});

	it('rejects empty and oversized values', () => {
		expect(validateHostname('')).toBe('Required.');
		expect(validateHostname(`${'a'.repeat(127)}.${'b'.repeat(126)}`)).toMatch(/Longer than/);
	});
});

describe('appValidation — validateDeployPath (deployment serving)', () => {
	it('accepts relative paths with nested segments', () => {
		expect(validateDeployPath('index.html')).toBeNull();
		expect(validateDeployPath('assets/app-a1b2.js')).toBeNull();
		expect(validateDeployPath('a/b/c.txt')).toBeNull();
	});

	it('rejects traversal, absolute, and empty-segment paths', () => {
		expect(validateDeployPath('../evil.html')).toMatch(/\.\./);
		expect(validateDeployPath('/abs.html')).toMatch(/Must not start/);
		expect(validateDeployPath('a//b.html')).toMatch(/empty/);
		expect(validateDeployPath('./x.html')).toMatch(/\./);
	});

	it('rejects empty and oversized paths', () => {
		expect(validateDeployPath('')).toBe('Empty path.');
		expect(validateDeployPath('a'.repeat(1025))).toMatch(/Longer than/);
	});
});
