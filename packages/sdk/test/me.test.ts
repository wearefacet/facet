// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it, vi } from 'vitest';
import { staticKey } from '../src/auth/provider.js';
import { createFacetClient, type FacetClient } from '../src/client.js';
import { can, scopeAliases } from '../src/me.js';
import type { Me } from '../src/me.js';

const BASE = 'https://facet.example.com';

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

function makeClient(mock: ReturnType<typeof vi.fn>): FacetClient {
	return createFacetClient({ baseUrl: BASE, auth: staticKey('fct_key'), fetchImpl: asFetch(mock) });
}

function mePayload(overrides: Partial<Me> = {}): Me {
	return {
		account: {
			id: '01ACC',
			display_name: 'App',
			email: 'app@example.com',
			mfa_enabled: false,
			mfa_enforcement: null,
			mfa_type: null
		},
		active_role: 'iam.Roles.editor',
		available_roles: ['iam.Roles.editor'],
		expires_at: null,
		assistant: { access: true, token_budget: 1000, name: 'Assistant' },
		connectivity: ['api', 'assistant'],
		channel: 'api',
		...overrides
	};
}

// The effective-manifest shape the backend serves an app token: concrete
// keys only, self-carved actions dropped, descendant carve-outs folded
// under `{key}.except.{action}`.
const effective: [Record<string, string[]>, Record<string, Record<string, string[]>>] = [
	{
		'crm.Contact': ['read', 'create'],
		'crm.Contact.except.read': ['crm.Contact.Internal'],
		'crm.Account': ['read']
	},
	{ 'crm.Contact': { read: ['own'] } }
];

describe('can — effective manifest (app token)', () => {
	const [permissions, scopes] = effective;

	it('answers all for a granted unrestricted action', () => {
		expect(can(permissions, scopes, 'read', 'crm.Account')).toBe('all');
	});

	it('answers scoped when the granting key carries aliases', () => {
		expect(can(permissions, scopes, 'read', 'crm.Contact')).toBe('scoped');
		expect(scopeAliases(permissions, scopes, 'read', 'crm.Contact')).toEqual(['own']);
	});

	it('denies an action the manifest never grants', () => {
		expect(can(permissions, scopes, 'delete', 'crm.Contact')).toBe('denied');
		expect(can(permissions, scopes, 'read', 'fin.Invoice')).toBe('denied');
	});

	it('denies a carved-out descendant through the except key', () => {
		expect(can(permissions, scopes, 'read', 'crm.Contact.Internal')).toBe('denied');
	});

	it('denies a doctype the grant never names', () => {
		expect(can(permissions, scopes, 'read', 'hr.Employee')).toBe('denied');
	});

	it('denies a key whose only granted action is fully carved', () => {
		// A stale or hand-built manifest that still carries a self-carved
		// action reads as denied: the backend drops such an action, and the
		// matcher subtracts it either way.
		expect(
			can(
				{ 'hr.Employee': ['read'], 'hr.Employee.except.read': ['hr.Employee'] },
				{},
				'read',
				'hr.Employee'
			)
		).toBe('denied');
	});

	it('grants the wildcard action', () => {
		const manifest = { 'crm.Contact': ['*'] };
		expect(can(manifest, {}, 'delete', 'crm.Contact')).toBe('all');
		expect(can(manifest, {}, 'delete', 'crm.Contact.Comment')).toBe('all');
	});

	it('reaches descendants through the domain-wildcard key', () => {
		const manifest = { 'crm.*': ['read'] };
		expect(can(manifest, {}, 'read', 'crm.Company')).toBe('all');
		expect(can(manifest, {}, 'read', 'crm.Company.Comment')).toBe('all');
		expect(can(manifest, {}, 'read', 'fin.Bill')).toBe('denied');
	});

	it('reaches every doctype through the global wildcard and subtracts carve-outs', () => {
		const manifest = { '*.*': ['read'], '*.*.except.read': ['core.SystemSettings'] };
		expect(can(manifest, {}, 'read', 'crm.Contact')).toBe('all');
		expect(can(manifest, {}, 'read', 'core.SystemSettings')).toBe('denied');
		expect(can(manifest, {}, 'read', 'core.SystemSettings.Extra')).toBe('denied');
	});

	it('denies everything without a manifest', () => {
		expect(can(undefined, undefined, 'read', 'crm.Contact')).toBe('denied');
		expect(scopeAliases(undefined, undefined, 'read', 'crm.Contact')).toEqual([]);
	});

	it('answers denied without any key when the path has no domain separator', () => {
		expect(can(permissions, scopes, 'read', 'Contact')).toBe('denied');
	});
});

describe('client — whoami, can, scopes, assistant', () => {
	it('whoami hits GET /Api/iam/me once and caches', async () => {
		const fetchImpl = vi.fn().mockResolvedValue(jsonResponse(200, mePayload()));
		const facet = makeClient(fetchImpl);
		await facet.whoami();
		await facet.whoami();
		expect(fetchImpl).toHaveBeenCalledTimes(1);
		const url = fetchImpl.mock.calls[0][0] as URL;
		expect(String(url)).toBe(`${BASE}/Api/iam/me`);
		expect((fetchImpl.mock.calls[0][1] as RequestInit).method).toBe('GET');
	});

	it('can and scopes ride the cached payload', async () => {
		const [permissions, scopes] = effective;
		const fetchImpl = vi
			.fn()
			.mockResolvedValue(jsonResponse(200, mePayload({ permissions, scopes })));
		const facet = makeClient(fetchImpl);
		expect(await facet.can('read', 'crm.Account')).toBe('all');
		expect(await facet.can('read', 'crm.Contact.Internal')).toBe('denied');
		expect(await facet.scopes('read', 'crm.Contact')).toEqual(['own']);
		expect(fetchImpl).toHaveBeenCalledTimes(1);
	});

	it('assistant surfaces the capability block', async () => {
		const fetchImpl = vi
			.fn()
			.mockResolvedValue(
				jsonResponse(
					200,
					mePayload({ assistant: { access: false, token_budget: null, name: null } })
				)
			);
		const facet = makeClient(fetchImpl);
		const capability = await facet.assistant();
		expect(capability.access).toBe(false);
		expect(capability.token_budget).toBeNull();
	});

	it('refreshRights re-fetches and replaces the cached payload', async () => {
		const fetchImpl = vi
			.fn()
			.mockResolvedValueOnce(
				jsonResponse(
					200,
					mePayload({ assistant: { access: false, token_budget: null, name: null } })
				)
			)
			.mockResolvedValue(jsonResponse(200, mePayload()));
		const facet = makeClient(fetchImpl);
		expect((await facet.assistant()).access).toBe(false);
		await facet.refreshRights();
		expect((await facet.assistant()).access).toBe(true);
		expect(fetchImpl).toHaveBeenCalledTimes(2);
	});
});
