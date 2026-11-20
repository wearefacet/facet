// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect, vi, afterEach } from 'vitest';
import {
	loadSettings,
	saveTimezone,
	saveLanguage,
	savePinnedDoctypes,
	togglePinnedDoctype,
	savePinnedCollectionViews,
	togglePinnedCollectionView,
	saveShowWelcome,
	getShowWelcome,
	systemTimezone,
	displayTimezone,
	AUTO_TIMEZONE,
	getTimezone,
	getLanguage,
	getPinnedDoctypes,
	getPinnedCollectionViews,
	reconcileLocale,
	resetSettings
} from './settings.svelte.js';
import { getLocale, setLocale } from '$lib/paraglide/runtime';

/** Mutable stand-in for the Paraglide locale strategies (cookie mirror). */
const localeState = vi.hoisted(() => ({ current: 'en' as string | undefined }));

vi.mock('$lib/paraglide/runtime', () => ({
	getLocale: vi.fn(() => localeState.current),
	setLocale: vi.fn((next: string) => {
		localeState.current = next;
	}),
	// The generated messages module imports this alongside `getLocale`; the
	// mock must define it or every message call throws.
	experimentalStaticLocale: undefined
}));

/**
 * Unit tests for the settings store — URL construction, CSRF header, and the
 * `auto` sentinel contract.
 *
 * These run in Node (no `window`), which exercises the SSR-safe branches: the
 * module-level store is a no-op and saves pass through `apiFetch` with the
 * injected `fetchFn` (cookies forwarded by the caller).
 */

const REFRESH_URL = '/Api/iam/refresh';

function jsonResponse(body: unknown, status = 200): Response {
	return new Response(JSON.stringify(body), {
		status,
		headers: { 'Content-Type': 'application/json' }
	});
}

/** Stub `apiFetch`'s network layer and capture the calls it makes. */
function makeStub() {
	const calls: Array<{ url: string; init?: RequestInit }> = [];
	const fetchFn = vi.fn(async (input: string | URL | Request, init?: RequestInit) => {
		const url = typeof input === 'string' ? input : input.toString();
		calls.push({ url, init });
		if (url === REFRESH_URL)
			return jsonResponse({ expires_at: Math.floor(Date.now() / 1000) + 900 });
		if (url === '/Api/settings/core') {
			return jsonResponse({
				app: 'core',
				values: {
					timezone: 'UTC',
					language: 'en',
					pinned_doctypes: [],
					pinned_collection_views: [],
					show_welcome: true
				}
			});
		}
		if (url.startsWith('/Api/settings/core/')) {
			const key = url.split('/').pop();
			return jsonResponse({
				app: 'core',
				key,
				value: init?.body ? JSON.parse(String(init.body)).value : '',
				updated_at: '2026-08-01T12:00:00Z'
			});
		}
		return jsonResponse({ error: 'not stubbed' }, 404);
	});
	return { fetchFn, calls };
}

describe('loadSettings', () => {
	afterEach(() => resetSettings());

	it('GETs /Api/settings/core and stores the values', async () => {
		const { fetchFn, calls } = makeStub();
		const values = await loadSettings(fetchFn);
		expect(values).toEqual({
			timezone: 'UTC',
			language: 'en',
			pinnedDoctypes: [],
			pinnedCollectionViews: [],
			showWelcome: true
		});
		expect(calls[0]?.url).toBe('/Api/settings/core');
		expect(getTimezone()).toBe('UTC');
		expect(getLanguage()).toBe('en');
		expect(getPinnedDoctypes()).toEqual([]);
		expect(getPinnedCollectionViews()).toEqual([]);
		expect(getShowWelcome()).toBe(true);
	});

	it('throws when the request fails', async () => {
		const fetchFn = vi.fn(async () => jsonResponse({ error: 'nope' }, 500));
		await expect(loadSettings(fetchFn)).rejects.toThrow();
	});
});

describe('saveTimezone / saveLanguage', () => {
	afterEach(() => resetSettings());

	it('PUTs /Api/settings/core/timezone with the CSRF header', async () => {
		const { fetchFn, calls } = makeStub();
		await saveTimezone('Europe/Paris', fetchFn);
		const call = calls[0];
		expect(call?.url).toBe('/Api/settings/core/timezone');
		expect(call?.init?.method).toBe('PUT');
		expect(JSON.parse(String(call?.init?.body))).toEqual({ value: 'Europe/Paris' });
		// The CSRF header must travel with the PUT — find it in the recorded init.
		expect(JSON.stringify(call?.init?.headers)).toContain('XMLHttpRequest');
		expect(getTimezone()).toBe('Europe/Paris');
	});

	it('rejects the AUTO_TIMEZONE sentinel', async () => {
		await expect(saveTimezone(AUTO_TIMEZONE)).rejects.toThrow();
	});

	it('PUTs /Api/settings/core/language', async () => {
		const { fetchFn, calls } = makeStub();
		await saveLanguage('en', fetchFn);
		expect(calls[0]?.url).toBe('/Api/settings/core/language');
		expect(JSON.parse(String(calls[0]?.init?.body))).toEqual({ value: 'en' });
		expect(getLanguage()).toBe('en');
	});

	it('throws with the backend error message on 422', async () => {
		const fetchFn = vi.fn(async () =>
			jsonResponse({ error: "Invalid timezone 'Bogus/Nowhere'" }, 422)
		);
		await expect(saveTimezone('Bogus/Nowhere', fetchFn)).rejects.toThrow('Invalid timezone');
	});
});

describe('show welcome', () => {
	afterEach(() => resetSettings());

	it('maps show_welcome from the load response', async () => {
		const fetchFn = vi.fn(async () =>
			jsonResponse({
				app: 'core',
				values: { timezone: 'UTC', language: 'en', show_welcome: false }
			})
		);
		await loadSettings(fetchFn);
		expect(getShowWelcome()).toBe(false);
	});

	it('defaults showWelcome to true when the response omits the key', async () => {
		const fetchFn = vi.fn(async () =>
			jsonResponse({ app: 'core', values: { timezone: 'UTC', language: 'en' } })
		);
		await loadSettings(fetchFn);
		expect(getShowWelcome()).toBe(true);
	});

	it('saveShowWelcome PUTs the boolean and updates the store', async () => {
		const { fetchFn, calls } = makeStub();
		await saveShowWelcome(false, fetchFn);
		const call = calls[0];
		expect(call?.url).toBe('/Api/settings/core/show_welcome');
		expect(call?.init?.method).toBe('PUT');
		expect(JSON.parse(String(call?.init?.body))).toEqual({ value: false });
		// The CSRF header must travel with the PUT.
		expect(JSON.stringify(call?.init?.headers)).toContain('XMLHttpRequest');
		expect(getShowWelcome()).toBe(false);
	});
});

describe('systemTimezone', () => {
	it('returns a non-empty IANA-style zone or the UTC fallback', () => {
		const zone = systemTimezone();
		expect(zone.length).toBeGreaterThan(0);
	});
});

describe('displayTimezone', () => {
	afterEach(() => resetSettings());

	it('falls back to the system zone before the settings load', () => {
		resetSettings();
		expect(displayTimezone()).toBe(systemTimezone());
	});

	it('returns the stored zone once loaded', async () => {
		const fetchFn = vi.fn(async () =>
			jsonResponse({
				app: 'core',
				values: { timezone: 'Europe/Paris', language: 'en' }
			})
		);
		await loadSettings(fetchFn);
		expect(displayTimezone()).toBe('Europe/Paris');
	});

	it('falls back to the system zone after reset (logout)', async () => {
		const fetchFn = vi.fn(async () =>
			jsonResponse({
				app: 'core',
				values: { timezone: 'Europe/Paris', language: 'en' }
			})
		);
		await loadSettings(fetchFn);
		resetSettings();
		expect(displayTimezone()).toBe(systemTimezone());
	});
});

describe('pinned doctypes', () => {
	afterEach(() => resetSettings());

	it('loads the persisted pinned list from the backend', async () => {
		const fetchFn = vi.fn(async () =>
			jsonResponse({
				app: 'core',
				values: { timezone: 'UTC', language: 'en', pinned_doctypes: ['crm.Company'] }
			})
		);
		await loadSettings(fetchFn);
		expect(getPinnedDoctypes()).toEqual(['crm.Company']);
	});

	it('PUTs the whole pinned list under pinned_doctypes', async () => {
		const { fetchFn, calls } = makeStub();
		await savePinnedDoctypes(['crm.Company', 'hr.Employee'], fetchFn);
		const call = calls[0];
		expect(call?.url).toBe('/Api/settings/core/pinned_doctypes');
		expect(call?.init?.method).toBe('PUT');
		expect(JSON.parse(String(call?.init?.body))).toEqual({
			value: ['crm.Company', 'hr.Employee']
		});
		expect(JSON.stringify(call?.init?.headers)).toContain('XMLHttpRequest');
		expect(getPinnedDoctypes()).toEqual(['crm.Company', 'hr.Employee']);
	});

	it('togglePinnedDoctype adds and removes a doctype', async () => {
		const { fetchFn } = makeStub();
		await loadSettings(fetchFn);
		togglePinnedDoctype('crm.Company', fetchFn);
		expect(getPinnedDoctypes()).toEqual(['crm.Company']);
		await togglePinnedDoctype('crm.Company', fetchFn);
		expect(getPinnedDoctypes()).toEqual([]);
	});
});

describe('pinned collection views', () => {
	afterEach(() => resetSettings());

	it('loads the persisted pinned view list from the backend', async () => {
		const fetchFn = vi.fn(async () =>
			jsonResponse({
				app: 'core',
				values: {
					timezone: 'UTC',
					language: 'en',
					pinned_doctypes: [],
					pinned_collection_views: ['01J0ABC123']
				}
			})
		);
		await loadSettings(fetchFn);
		expect(getPinnedCollectionViews()).toEqual(['01J0ABC123']);
	});

	it('PUTs the whole pinned view list under pinned_collection_views', async () => {
		const { fetchFn, calls } = makeStub();
		await savePinnedCollectionViews(['01J0ABC123', '01J0XYZ789'], fetchFn);
		const call = calls[0];
		expect(call?.url).toBe('/Api/settings/core/pinned_collection_views');
		expect(call?.init?.method).toBe('PUT');
		expect(JSON.parse(String(call?.init?.body))).toEqual({
			value: ['01J0ABC123', '01J0XYZ789']
		});
		expect(JSON.stringify(call?.init?.headers)).toContain('XMLHttpRequest');
		expect(getPinnedCollectionViews()).toEqual(['01J0ABC123', '01J0XYZ789']);
	});

	it('togglePinnedCollectionView adds and removes a view', async () => {
		const { fetchFn } = makeStub();
		await loadSettings(fetchFn);
		await togglePinnedCollectionView('01J0ABC123', fetchFn);
		expect(getPinnedCollectionViews()).toEqual(['01J0ABC123']);
		await togglePinnedCollectionView('01J0ABC123', fetchFn);
		expect(getPinnedCollectionViews()).toEqual([]);
	});
});

describe('reconcileLocale', () => {
	afterEach(() => {
		resetSettings();
		localeState.current = 'en';
		vi.unstubAllGlobals();
		vi.clearAllMocks();
	});

	/** Stub a browser enough for the reconcile path to run. */
	function stubBrowser() {
		const reload = vi.fn();
		vi.stubGlobal('window', { location: { reload } });
		return reload;
	}

	it('is a no-op outside the browser', () => {
		localeState.current = 'fr';
		reconcileLocale('en');
		expect(vi.mocked(setLocale)).not.toHaveBeenCalled();
		expect(localeState.current).toBe('fr');
	});

	it('re-aligns the cookie and reloads when the locale disagrees', () => {
		const reload = stubBrowser();
		localeState.current = 'fr';
		reconcileLocale('en');
		expect(vi.mocked(setLocale)).toHaveBeenCalledWith('en', { reload: false });
		expect(getLocale()).toBe('en');
		expect(reload).toHaveBeenCalledTimes(1);
	});

	it('stays on the current locale when the mirror write is refused', () => {
		const reload = stubBrowser();
		localeState.current = 'fr';
		vi.mocked(setLocale).mockImplementationOnce(() => {});
		reconcileLocale('en');
		expect(reload).not.toHaveBeenCalled();
		expect(localeState.current).toBe('fr');
	});

	it('does nothing when the locale already matches', () => {
		const reload = stubBrowser();
		reconcileLocale('en');
		expect(vi.mocked(setLocale)).not.toHaveBeenCalled();
		expect(reload).not.toHaveBeenCalled();
	});
});
