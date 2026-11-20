// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect, afterEach, vi } from 'vitest';
import {
	getPreviewSession,
	isPreviewActive,
	setPreviewSession,
	clearPreviewSession,
	builderPreviewActive,
	previewExpired,
	type PreviewSession
} from './previewSession.svelte';
import { doctypeRegistryCache, domainListCache } from './datasource/clientCache.js';

/**
 * Unit tests for the preview-session store's pure URL predicates and the
 * store round-trip. These run in Node (no `window`), which exercises the
 * SSR-safe branches: the module-level hydration block is skipped and the
 * storage/cookie writes are no-ops.
 */

const SESSION: PreviewSession = {
	draftId: '_abc',
	token: 'test-token',
	expiresAt: Math.floor(Date.now() / 1000) + 60
};

describe('builderPreviewActive', () => {
	it('matches the builder preview entry route', () => {
		expect(builderPreviewActive('/Builder/_abc/preview')).toBe(true);
		expect(builderPreviewActive('/Builder/_abc/preview/')).toBe(true);
		expect(builderPreviewActive('/Builder/_abc/preview/crm/Company')).toBe(true);
	});

	it('does not match build-mode tabs', () => {
		expect(builderPreviewActive('/Builder/_abc/overview')).toBe(false);
		expect(builderPreviewActive('/Builder/_abc/doctypes')).toBe(false);
		expect(builderPreviewActive('/Builder/_abc')).toBe(false);
		expect(builderPreviewActive('/Builder')).toBe(false);
	});

	it('does not match a segment that merely starts with "preview"', () => {
		expect(builderPreviewActive('/Builder/_abc/previewx')).toBe(false);
	});

	it('does not match live routes', () => {
		expect(builderPreviewActive('/_abc')).toBe(false);
		expect(builderPreviewActive('/Settings')).toBe(false);
	});
});

describe('previewExpired', () => {
	it('is not expired inside the bound draft live URL', () => {
		expect(previewExpired(SESSION, '/_abc')).toBe(false);
		expect(previewExpired(SESSION, '/_abc/Widget/01JX')).toBe(false);
	});

	it('is not expired while the entry redirect is in flight', () => {
		expect(previewExpired(SESSION, '/Builder/_abc/preview')).toBe(false);
		expect(previewExpired(SESSION, '/Builder/_abc/preview/crm/Company')).toBe(false);
	});

	it('expires once the user leaves the draft and the entry route', () => {
		expect(previewExpired(SESSION, '/Settings')).toBe(true);
		expect(previewExpired(SESSION, '/crm/Company')).toBe(true);
		// Another draft's builder routes are outside the bound draft too.
		expect(previewExpired(SESSION, '/Builder/_xyz/overview')).toBe(true);
		expect(previewExpired(SESSION, '/Builder')).toBe(true);
	});

	it('scopes the live-URL check to the exact draft id', () => {
		// A live domain whose id merely starts with the draft id must not
		// count as the draft's URL.
		expect(previewExpired(SESSION, '/_abcd')).toBe(true);
	});
});

describe('store round-trip', () => {
	afterEach(() => clearPreviewSession());

	it('set/get/clear keeps the session in module state', () => {
		expect(isPreviewActive()).toBe(false);

		setPreviewSession(SESSION);
		expect(getPreviewSession()).toEqual(SESSION);
		expect(isPreviewActive()).toBe(true);

		clearPreviewSession();
		expect(getPreviewSession()).toBeNull();
		expect(isPreviewActive()).toBe(false);
	});

	it('drops the principal-scoped definition caches on set and on clear', () => {
		// While the overlay is active the cached `core.DocType` / `core.Domain`
		// snapshots are draft-scoped, so both stores drop when the overlay
		// engages and when it clears — otherwise a stale principal-scoped
		// snapshot survives the switch for up to the 60s TTL.
		const registrySpy = vi.spyOn(doctypeRegistryCache, 'invalidate');
		const domainListSpy = vi.spyOn(domainListCache, 'invalidate');

		setPreviewSession(SESSION);
		expect(registrySpy).toHaveBeenCalled();
		expect(domainListSpy).toHaveBeenCalled();

		registrySpy.mockClear();
		domainListSpy.mockClear();

		clearPreviewSession();
		expect(registrySpy).toHaveBeenCalled();
		expect(domainListSpy).toHaveBeenCalled();
	});
});
