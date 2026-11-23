// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect, vi, afterEach } from 'vitest';
import {
	viewStateStorageKey,
	loadViewState,
	saveViewState,
	type PersistedViewState
} from './viewState.js';

/**
 * Unit tests for the persisted listing-state store.
 *
 * The module reads `window.localStorage` at call time, so each test stubs a
 * `window` with an in-memory storage (`vi.stubGlobal`). No module-reload
 * dance is needed — the module holds no module-level browser flag, unlike
 * `recentDocuments.svelte.ts`.
 */

/** A minimal in-memory localStorage implementing the methods the store uses. */
function makeStorage() {
	const store: Record<string, string> = {};
	return {
		getItem: vi.fn((k: string) => (k in store ? store[k] : null)),
		setItem: vi.fn((k: string, v: string) => {
			store[k] = v;
		}),
		removeItem: vi.fn((k: string) => {
			delete store[k];
		})
	};
}

function stubWindow(storage = makeStorage()) {
	vi.stubGlobal('window', { localStorage: storage });
	return storage;
}

afterEach(() => {
	vi.unstubAllGlobals();
});

const KEY = viewStateStorageKey('crm.Deal', 'view-1', 'live');

describe('viewStateStorageKey', () => {
	it('namespaces by doctype, view id, and trash mode', () => {
		expect(viewStateStorageKey('crm.Deal', '01J', 'live')).toBe(
			'facet.viewState.crm.Deal.01J.live'
		);
		expect(viewStateStorageKey('crm.Deal', '01J', 'deleted')).toBe(
			'facet.viewState.crm.Deal.01J.deleted'
		);
		expect(viewStateStorageKey('crm.Deal', 'default', 'live')).toBe(
			'facet.viewState.crm.Deal.default.live'
		);
	});
});

describe('saveViewState / loadViewState', () => {
	it('round-trips the full record', () => {
		stubWindow();
		const state: PersistedViewState = {
			sort: { key: 'value', desc: true },
			filters: { status__eq: 'open', search: 'acme' },
			rowsPerPage: 100
		};
		saveViewState(KEY, state);
		expect(loadViewState(KEY)).toEqual(state);
	});

	it('round-trips a record with a null sort and no rowsPerPage', () => {
		stubWindow();
		saveViewState(KEY, { sort: null, filters: {} });
		expect(loadViewState(KEY)).toEqual({ sort: null, filters: {} });
	});

	it('overwrites a previous record for the same key', () => {
		stubWindow();
		saveViewState(KEY, { sort: { key: 'a', desc: false }, filters: {} });
		saveViewState(KEY, { sort: { key: 'b', desc: true }, filters: { x__eq: '1' } });
		expect(loadViewState(KEY)?.sort).toEqual({ key: 'b', desc: true });
	});

	it('isolates records per view and per trash mode', () => {
		stubWindow();
		saveViewState(viewStateStorageKey('crm.Deal', 'v1', 'live'), {
			sort: { key: 'a', desc: false },
			filters: {}
		});
		expect(loadViewState(viewStateStorageKey('crm.Deal', 'v2', 'live'))).toBeNull();
		expect(loadViewState(viewStateStorageKey('crm.Deal', 'v1', 'deleted'))).toBeNull();
	});
});

describe('loadViewState tolerates bad data', () => {
	it('returns null for a missing entry', () => {
		stubWindow();
		expect(loadViewState(KEY)).toBeNull();
	});

	it('returns null for corrupt JSON', () => {
		const storage = stubWindow();
		storage.setItem(KEY, '{not valid json');
		expect(loadViewState(KEY)).toBeNull();
	});

	it('returns null when the blob is not an object', () => {
		const storage = stubWindow();
		storage.setItem(KEY, '[1,2,3]');
		expect(loadViewState(KEY)).toBeNull();
	});

	it('degrades malformed members one by one', () => {
		const storage = stubWindow();
		storage.setItem(
			KEY,
			JSON.stringify({
				sort: 'open',
				filters: ['nope'],
				rowsPerPage: '25'
			})
		);
		expect(loadViewState(KEY)).toEqual({ sort: null, filters: {} });
	});

	it('drops a rowsPerPage that is not an integer of at least 1', () => {
		const storage = stubWindow();
		storage.setItem(KEY, JSON.stringify({ sort: null, filters: {}, rowsPerPage: 0 }));
		expect(loadViewState(KEY)).toEqual({ sort: null, filters: {} });
		storage.setItem(KEY, JSON.stringify({ sort: null, filters: {}, rowsPerPage: 2.5 }));
		expect(loadViewState(KEY)).toEqual({ sort: null, filters: {} });
	});
});

describe('SSR (no window)', () => {
	it('load returns null and save is a no-op', () => {
		expect(() => saveViewState(KEY, { sort: null, filters: {} })).not.toThrow();
		expect(loadViewState(KEY)).toBeNull();
	});
});
