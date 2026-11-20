// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';
import type { NavDomain } from './navTypes';
import { DocumentDataDriver } from './datasource/DocumentDriver';
import { domainListCache, doctypeRegistryCache } from './datasource/clientCache.js';
import { setPermissions } from './permissions.svelte';

// The rebuild helpers fetch through `buildNavModel`; the mock stands in for
// the DataSource layer so tests observe the fetch options and the install
// calls, not the network shape.
vi.mock('$lib/navModel', () => ({
	buildNavModel: vi.fn()
}));

import { buildNavModel } from '$lib/navModel';
import {
	getNavDomains,
	getNavIsDraft,
	getNavLiveDomains,
	getDomainLabel,
	setLiveNav,
	setDraftNav,
	setNavLiveDomains,
	prependDraft,
	rebuildLiveNav,
	setLiveFromLoad,
	rebuildDraftNav,
	rebuildPreviewNav,
	loadBuilderEntryNav
} from './navState.svelte';

const mockBuildNavModel = vi.mocked(buildNavModel);

function navDomain(id: string, label: string): NavDomain {
	return { id, label, color: '#000000', doctypes: [], updatedAt: undefined };
}

/**
 * Builds a fetch mock that asserts both caches were already invalidated by
 * the time the fetch runs — the ordering the stale-TTL guard depends on.
 */
function buildNavModelAssertingCacheDrop(model: NavDomain): void {
	const registrySpy = vi.spyOn(doctypeRegistryCache, 'invalidate');
	const domainListSpy = vi.spyOn(domainListCache, 'invalidate');
	mockBuildNavModel.mockImplementation(async () => {
		expect(registrySpy).toHaveBeenCalled();
		expect(domainListSpy).toHaveBeenCalled();
		return [model];
	});
}

beforeEach(() => {
	mockBuildNavModel.mockReset();
	setPermissions(null);
	// Baseline model so "keeps the current model" assertions have something
	// to compare against.
	setLiveNav([navDomain('crm', 'CRM')]);
	setNavLiveDomains([]);
});

afterEach(() => {
	vi.restoreAllMocks();
	// Back to the empty module state so tests stay order-independent.
	setLiveNav([]);
	setDraftNav([]);
	setNavLiveDomains([]);
});

describe('setLiveFromLoad', () => {
	it('installs the load result and clears draft mode', () => {
		setDraftNav([navDomain('_abc', 'Supplier (draft)')]);
		expect(getNavIsDraft()).toBe(true);

		setLiveFromLoad([navDomain('hr', 'Human Resources')]);

		expect(getNavDomains().map((d) => d.id)).toEqual(['hr']);
		expect(getNavIsDraft()).toBe(false);
	});
});

describe('rebuildLiveNav', () => {
	it('builds with the given permissions and pinned set and installs as live', async () => {
		mockBuildNavModel.mockResolvedValue([navDomain('hr', 'Human Resources')]);
		const permissions = { 'hr.Employee': ['read'] };

		await rebuildLiveNav({ permissions, pinnedDoctypes: ['hr.Employee'] });

		expect(mockBuildNavModel).toHaveBeenCalledWith(expect.any(DocumentDataDriver), permissions, {
			pinnedDoctypes: ['hr.Employee']
		});
		expect(getNavDomains().map((d) => d.id)).toEqual(['hr']);
		expect(getNavIsDraft()).toBe(false);
	});

	it('keeps the current model when the fetch fails', async () => {
		mockBuildNavModel.mockRejectedValue(new Error('boom'));

		await rebuildLiveNav({ permissions: { '*.*': ['*'] } });

		expect(getNavDomains().map((d) => d.id)).toEqual(['crm']);
	});
});

describe('rebuildDraftNav', () => {
	it('drops both caches before the fetch and installs as draft', async () => {
		const draft = navDomain('_abc', 'Supplier (draft)');
		buildNavModelAssertingCacheDrop(draft);
		setPermissions({ 'core.Domain': ['read'] });

		await rebuildDraftNav();

		expect(mockBuildNavModel).toHaveBeenCalledWith(
			expect.any(DocumentDataDriver),
			{
				'core.Domain': ['read']
			},
			{ drafts: true }
		);
		expect(getNavDomains().map((d) => d.id)).toEqual(['_abc']);
		expect(getNavIsDraft()).toBe(true);
	});

	it('passes undefined (not null) permissions when the store is empty', async () => {
		mockBuildNavModel.mockResolvedValue([]);

		await rebuildDraftNav();

		expect(mockBuildNavModel).toHaveBeenCalledWith(expect.any(DocumentDataDriver), undefined, {
			drafts: true
		});
	});

	it('keeps the current model when the fetch fails', async () => {
		mockBuildNavModel.mockRejectedValue(new Error('boom'));

		await rebuildDraftNav();

		expect(getNavDomains().map((d) => d.id)).toEqual(['crm']);
	});
});

describe('rebuildPreviewNav', () => {
	it('drops both caches before the fetch and installs as live', async () => {
		const draft = navDomain('_abc', 'Supplier (draft)');
		buildNavModelAssertingCacheDrop(draft);

		await rebuildPreviewNav(['_abc.Widget']);

		expect(mockBuildNavModel).toHaveBeenCalledWith(expect.any(DocumentDataDriver), undefined, {
			pinnedDoctypes: ['_abc.Widget']
		});
		expect(getNavDomains().map((d) => d.id)).toEqual(['_abc']);
		expect(getNavIsDraft()).toBe(false);
	});

	it('omits the permission manifest — the preview carve-out is the authority', async () => {
		// A preview session suppresses the real-user manifest on every preview
		// rebuild (the layout's own effect does the same): the manifest would
		// filter the draft's doctypes out of the sidebar.
		setPermissions({ 'hr.Employee': ['read'] });
		mockBuildNavModel.mockResolvedValue([]);

		await rebuildPreviewNav();

		expect(mockBuildNavModel).toHaveBeenCalledWith(expect.any(DocumentDataDriver), undefined, {
			pinnedDoctypes: undefined
		});
	});

	it('keeps the current model when the fetch fails', async () => {
		mockBuildNavModel.mockRejectedValue(new Error('boom'));

		await rebuildPreviewNav();

		expect(getNavDomains().map((d) => d.id)).toEqual(['crm']);
	});
});

describe('loadBuilderEntryNav', () => {
	it('installs the draft model and the live-dialog model', async () => {
		mockBuildNavModel.mockImplementation(async (_driver, _perms, opts) =>
			opts?.drafts ? [navDomain('_abc', 'Supplier (draft)')] : [navDomain('hr', 'HR')]
		);

		loadBuilderEntryNav();
		await vi.waitFor(() => expect(getNavDomains().map((d) => d.id)).toEqual(['_abc']));

		expect(getNavIsDraft()).toBe(true);
		expect(getNavLiveDomains().map((d) => d.id)).toEqual(['hr']);
		// Both fetch options must have been requested — drafts for the sidebar,
		// live for the EditDomainDialog.
		const calls = mockBuildNavModel.mock.calls;
		expect(calls.some(([, , opts]) => opts?.drafts === true)).toBe(true);
		expect(calls.some(([, , opts]) => opts?.drafts === false)).toBe(true);
	});

	it('a failed draft fetch keeps the current model while the live fetch lands', async () => {
		mockBuildNavModel.mockImplementation(async (_driver, _perms, opts) =>
			opts?.drafts ? Promise.reject(new Error('boom')) : Promise.resolve([navDomain('hr', 'HR')])
		);

		loadBuilderEntryNav();
		await vi.waitFor(() => expect(getNavLiveDomains().map((d) => d.id)).toEqual(['hr']));

		expect(getNavDomains().map((d) => d.id)).toEqual(['crm']);
	});

	it('a failed live fetch keeps the dialog list while the draft model lands', async () => {
		mockBuildNavModel.mockImplementation(async (_driver, _perms, opts) =>
			opts?.drafts
				? Promise.resolve([navDomain('_abc', 'Supplier (draft)')])
				: Promise.reject(new Error('boom'))
		);

		loadBuilderEntryNav();
		await vi.waitFor(() => expect(getNavDomains().map((d) => d.id)).toEqual(['_abc']));

		expect(getNavLiveDomains()).toEqual([]);
	});
});

describe('prependDraft', () => {
	it('prepends the draft and switches the sidebar to drafts', () => {
		setLiveNav([navDomain('hr', 'HR')]);

		prependDraft(navDomain('_abc', 'Supplier (draft)'));

		expect(getNavDomains().map((d) => d.id)).toEqual(['_abc', 'hr']);
		expect(getNavIsDraft()).toBe(true);
	});

	it('replaces an existing row with the same id instead of duplicating it', () => {
		// The draft creation races its own WS-driven rebuilds; one of them can
		// land the draft before the POST response does. Prepending over it
		// must not keep two rows with the same id.
		setDraftNav([navDomain('_abc', 'stale'), navDomain('hr', 'HR')]);

		prependDraft(navDomain('_abc', 'Supplier (draft)'));

		expect(getNavDomains().map((d) => d.id)).toEqual(['_abc', 'hr']);
	});
});

describe('getDomainLabel', () => {
	it('resolves the label and falls back to the id', () => {
		setLiveNav([navDomain('crm', 'CRM')]);
		expect(getDomainLabel('crm')).toBe('CRM');
		expect(getDomainLabel('_missing')).toBe('_missing');
	});
});
