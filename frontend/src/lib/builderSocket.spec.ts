// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

// The socket client talks to a real socket; the tests only need to observe
// the connect/subscribe/recover wiring. The unsub stubs are distinct so the
// cleanup assertions can tell them apart.
vi.mock('$lib/websocket.svelte.js', () => ({
	getWebSocketClient: vi.fn(() => ({ connect: connectSpy })),
	subscribeToDocument: vi.fn(() => unsubDocSpy),
	onWebSocketReconnect: vi.fn(() => unsubReconnectSpy),
	ensureWebSocketConnected: vi.fn()
}));

import {
	subscribeToDocument,
	onWebSocketReconnect,
	ensureWebSocketConnected
} from '$lib/websocket.svelte.js';
import { subscribeBuilderModel } from './builderSocket.svelte';

const connectSpy = vi.fn();
const unsubDocSpy = vi.fn();
const unsubReconnectSpy = vi.fn();

const mockSubscribe = vi.mocked(subscribeToDocument);
const mockReconnect = vi.mocked(onWebSocketReconnect);
const mockEnsure = vi.mocked(ensureWebSocketConnected);

let addEventListener: ReturnType<typeof vi.fn>;
let removeEventListener: ReturnType<typeof vi.fn>;
let onVisibilityChange: (() => void) | undefined;

beforeEach(() => {
	vi.clearAllMocks();
	onVisibilityChange = undefined;
	addEventListener = vi.fn((kind: string, listener: () => void) => {
		if (kind === 'visibilitychange') onVisibilityChange = listener;
	});
	removeEventListener = vi.fn();
	vi.stubGlobal('document', {
		visibilityState: 'visible',
		addEventListener,
		removeEventListener
	});
});

afterEach(() => {
	vi.unstubAllGlobals();
});

function lastVisibilityListener(): (() => void) | undefined {
	return onVisibilityChange;
}

describe('subscribeBuilderModel', () => {
	it('connects and subscribes the per-draft and collection channels', () => {
		const onModelChange = vi.fn();

		subscribeBuilderModel({ draftDomain: '_abc', onModelChange });

		expect(connectSpy).toHaveBeenCalledOnce();
		expect(mockSubscribe).toHaveBeenCalledTimes(2);
		expect(mockSubscribe).toHaveBeenCalledWith('/core/Domain/_abc', onModelChange);
		expect(mockSubscribe).toHaveBeenCalledWith('/core/DocType', onModelChange);
	});

	it('skips the per-draft channel on the Builder landing (no param)', () => {
		// The collection channel covers the landing page too — drafts created
		// from existing domains fire `registered` events per copied doctype
		// there, before any draft-scoped subscription exists.
		const onModelChange = vi.fn();

		subscribeBuilderModel({ draftDomain: '', onModelChange });

		expect(mockSubscribe).toHaveBeenCalledTimes(1);
		expect(mockSubscribe).toHaveBeenCalledWith('/core/DocType', onModelChange);
	});

	it('never subscribes a per-doctype loop', () => {
		// A loop over the doctypes that exist at subscribe time can never
		// receive events for doctypes created later — the collection channel
		// (`fanout:core.DocType`) must carry every `core.DocType` event.
		subscribeBuilderModel({ draftDomain: '_abc', onModelChange: vi.fn() });

		const paths = mockSubscribe.mock.calls.map((c) => c[0]);
		expect(paths).toEqual(['/core/Domain/_abc', '/core/DocType']);
	});

	it('registers the reconnect handler on onModelChange', () => {
		const onModelChange = vi.fn();

		subscribeBuilderModel({ draftDomain: '_abc', onModelChange });

		expect(mockReconnect).toHaveBeenCalledWith(onModelChange);
	});

	it('reconnects immediately when the tab becomes visible', () => {
		subscribeBuilderModel({ draftDomain: '_abc', onModelChange: vi.fn() });

		const listener = lastVisibilityListener();
		expect(listener).toBeDefined();
		listener?.();

		expect(mockEnsure).toHaveBeenCalledOnce();
	});

	it('does not reconnect when the tab is hidden', () => {
		vi.stubGlobal('document', {
			visibilityState: 'hidden',
			addEventListener,
			removeEventListener
		});

		subscribeBuilderModel({ draftDomain: '_abc', onModelChange: vi.fn() });
		lastVisibilityListener()?.();

		expect(mockEnsure).not.toHaveBeenCalled();
	});

	it('cleanup unsubscribes every channel and removes the listener', () => {
		const cleanup = subscribeBuilderModel({ draftDomain: '_abc', onModelChange: vi.fn() });
		const listener = lastVisibilityListener();

		cleanup();

		expect(unsubDocSpy).toHaveBeenCalledTimes(2);
		expect(unsubReconnectSpy).toHaveBeenCalledTimes(1);
		expect(removeEventListener).toHaveBeenCalledWith('visibilitychange', listener);
	});

	it('cleanup after the landing-page variant unsubscribes only the collection channel', () => {
		const cleanup = subscribeBuilderModel({ draftDomain: '', onModelChange: vi.fn() });

		cleanup();

		expect(unsubDocSpy).toHaveBeenCalledTimes(1);
		expect(unsubReconnectSpy).toHaveBeenCalledTimes(1);
	});
});
