// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/** The token pair one OAuth session holds. `null` marks a missing half. */
export interface StoredTokens {
	accessToken: string | null;
	refreshToken: string | null;
}

/**
 * Reads and writes the OAuth token pair. The default browser storage keeps
 * the access token in memory and the refresh token in `localStorage`. A
 * caller can inject any store, such as `sessionStorage` or plain memory for
 * tests.
 */
export interface TokenStorage {
	/** The stored pair, or `null` when nothing is stored. */
	read(): StoredTokens | null;
	/** Store or replace the pair. */
	write(tokens: StoredTokens): void;
	/** Drop every stored token. */
	clear(): void;
}

/**
 * Holds the in-flight sign-in state across the redirect round-trip. The
 * top-level navigation destroys the page, so the `state` and the PKCE
 * `verifier` must survive it. The default store rides `sessionStorage`.
 */
export interface FlowStore {
	/** The stored flow, or `null` when no sign-in is in progress. */
	read(): { state: string; verifier: string } | null;
	/** Store or replace the flow. */
	write(flow: { state: string; verifier: string }): void;
	/** Drop the stored flow. */
	clear(): void;
}

const REFRESH_KEY = 'facet.oauth.refresh';
const FLOW_STATE_KEY = 'facet.oauth.state';
const FLOW_VERIFIER_KEY = 'facet.oauth.verifier';

/** Access token in memory, refresh token in `localStorage`. */
export function browserTokenStorage(): TokenStorage {
	let accessToken: string | null = null;
	return {
		read: () => {
			const refreshToken = webStorageGet(localStorageRef(), REFRESH_KEY);
			if (accessToken === null && refreshToken === null) {
				return null;
			}
			return { accessToken, refreshToken };
		},
		write: (tokens) => {
			accessToken = tokens.accessToken;
			if (tokens.refreshToken !== null) {
				webStorageSet(localStorageRef(), REFRESH_KEY, tokens.refreshToken);
			}
		},
		clear: () => {
			accessToken = null;
			webStorageRemove(localStorageRef(), REFRESH_KEY);
		}
	};
}

/** Both tokens in memory. Useful for tests and non-browser runtimes. */
export function memoryTokenStorage(): TokenStorage {
	let tokens: StoredTokens | null = null;
	return {
		read: () => (tokens?.accessToken === null && tokens?.refreshToken === null ? null : tokens),
		write: (next) => {
			tokens = next;
		},
		clear: () => {
			tokens = null;
		}
	};
}

/** Flow state in `sessionStorage`, with a memory fallback. */
export function browserFlowStore(): FlowStore {
	let memory: { state: string; verifier: string } | null = null;
	return {
		read: () => {
			const state = webStorageGet(sessionStorageRef(), FLOW_STATE_KEY);
			const verifier = webStorageGet(sessionStorageRef(), FLOW_VERIFIER_KEY);
			return state === null || verifier === null ? memory : { state, verifier };
		},
		write: (flow) => {
			memory = flow;
			webStorageSet(sessionStorageRef(), FLOW_STATE_KEY, flow.state);
			webStorageSet(sessionStorageRef(), FLOW_VERIFIER_KEY, flow.verifier);
		},
		clear: () => {
			memory = null;
			webStorageRemove(sessionStorageRef(), FLOW_STATE_KEY);
			webStorageRemove(sessionStorageRef(), FLOW_VERIFIER_KEY);
		}
	};
}

/** Flow state in memory only. Useful for tests and non-browser runtimes. */
export function memoryFlowStore(): FlowStore {
	let flow: { state: string; verifier: string } | null = null;
	return {
		read: () => flow,
		write: (next) => {
			flow = next;
		},
		clear: () => {
			flow = null;
		}
	};
}

function localStorageRef(): Storage | undefined {
	try {
		return typeof localStorage === 'undefined' ? undefined : localStorage;
	} catch {
		return undefined;
	}
}

function sessionStorageRef(): Storage | undefined {
	try {
		return typeof sessionStorage === 'undefined' ? undefined : sessionStorage;
	} catch {
		return undefined;
	}
}

function webStorageGet(store: Storage | undefined, key: string): string | null {
	if (store === undefined) {
		return null;
	}
	try {
		return store.getItem(key);
	} catch {
		return null;
	}
}

function webStorageSet(store: Storage | undefined, key: string, value: string): void {
	if (store === undefined) {
		return;
	}
	try {
		store.setItem(key, value);
	} catch {
		// A blocked or full store degrades the session to memory only.
	}
}

function webStorageRemove(store: Storage | undefined, key: string): void {
	if (store === undefined) {
		return;
	}
	try {
		store.removeItem(key);
	} catch {
		// Same as set: the store is unusable, the memory half still clears.
	}
}
