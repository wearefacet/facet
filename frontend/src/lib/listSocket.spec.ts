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
	ensureWebSocketConnected,
	type WsDocumentEvent
} from '$lib/websocket.svelte.js';
import {
	subscribeCollectionRefresh,
	isCollectionEvent,
	REFRESH_DEBOUNCE_MS
} from './listSocket.svelte';

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
	vi.useFakeTimers();
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
	vi.useRealTimers();
});

// The wire channel is the Redis pub/sub channel plus the event suffix
// (`fanout:crm.Company:updated`); the identity filter reads the publish
// headers, not the channel.
function frame(event: string, domain: string, docType: string, id: string): WsDocumentEvent {
	return {
		channel: `fanout:${domain}.${docType}:${event}`,
		event,
		payload: { id },
		headers: { domain, doc_type: docType }
	};
}

/** The listener registered on the collection channel. */
function channelHandler(): (event: WsDocumentEvent) => void {
	const call = mockSubscribe.mock.calls[0];
	return call[1] as (event: WsDocumentEvent) => void;
}

function subscribe(refresh: () => void): () => void {
	return subscribeCollectionRefresh({ domain: 'crm', docType: 'Company', refresh });
}

describe('isCollectionEvent', () => {
	it('matches frames whose publish headers name the collection', () => {
		expect(
			isCollectionEvent(frame('updated', 'crm', 'Company', 'crm.Company.c1'), 'crm', 'Company')
		).toBe(true);
		expect(
			isCollectionEvent(frame('closed', 'crm', 'Company', 'crm.Company.c1'), 'crm', 'Company')
		).toBe(true);
	});

	it('ignores frames for other doctypes', () => {
		expect(
			isCollectionEvent(frame('updated', 'crm', 'Deal', 'crm.Deal.d1'), 'crm', 'Company')
		).toBe(false);
		expect(
			isCollectionEvent(frame('updated', 'iam', 'Company', 'iam.Company.c1'), 'crm', 'Company')
		).toBe(false);
	});

	it('ignores child_changed frames that name the listed doctype as parent', () => {
		expect(
			isCollectionEvent(
				frame('child_changed', 'crm', 'Company', 'crm.Company.p1'),
				'crm',
				'Company'
			)
		).toBe(false);
	});
});

describe('subscribeCollectionRefresh', () => {
	it('connects and subscribes the collection path', () => {
		const refresh = vi.fn();

		subscribe(refresh);

		expect(connectSpy).toHaveBeenCalledOnce();
		expect(mockSubscribe).toHaveBeenCalledTimes(1);
		expect(mockSubscribe).toHaveBeenCalledWith('/crm/Company', expect.any(Function));
	});

	it('coalesces N events into one refetch after the debounce', () => {
		const refresh = vi.fn();
		subscribe(refresh);
		const handler = channelHandler();

		handler(frame('created', 'crm', 'Company', 'crm.Company.c1'));
		handler(frame('updated', 'crm', 'Company', 'crm.Company.c1'));
		handler(frame('deleted', 'crm', 'Company', 'crm.Company.c2'));

		expect(refresh).not.toHaveBeenCalled();

		vi.advanceTimersByTime(REFRESH_DEBOUNCE_MS);

		expect(refresh).toHaveBeenCalledTimes(1);
	});

	it('ignores frames for other doctypes (the client dispatches every frame to every listener)', () => {
		const refresh = vi.fn();
		subscribe(refresh);

		channelHandler()(frame('updated', 'crm', 'Deal', 'crm.Deal.d1'));
		channelHandler()(frame('created', 'iam', 'Account', 'iam.Account.ada'));

		vi.advanceTimersByTime(REFRESH_DEBOUNCE_MS);

		expect(refresh).not.toHaveBeenCalled();
	});

	it('ignores child_changed frames that name the listed doctype as parent', () => {
		const refresh = vi.fn();
		subscribe(refresh);

		channelHandler()(frame('child_changed', 'crm', 'Company', 'crm.Company.p1'));

		vi.advanceTimersByTime(REFRESH_DEBOUNCE_MS);

		expect(refresh).not.toHaveBeenCalled();
	});

	it('refetches on reconnect (no replay while disconnected)', () => {
		const refresh = vi.fn();
		subscribe(refresh);

		expect(mockReconnect).toHaveBeenCalledTimes(1);
		const reconnect = mockReconnect.mock.calls[0][0] as () => void;
		reconnect();

		vi.advanceTimersByTime(REFRESH_DEBOUNCE_MS);

		expect(refresh).toHaveBeenCalledTimes(1);
	});

	it('folds a reconnect into an event burst already waiting on the debounce', () => {
		const refresh = vi.fn();
		subscribe(refresh);

		channelHandler()(frame('updated', 'crm', 'Company', 'crm.Company.c1'));
		const reconnect = mockReconnect.mock.calls[0][0] as () => void;
		reconnect();

		vi.advanceTimersByTime(REFRESH_DEBOUNCE_MS);

		expect(refresh).toHaveBeenCalledTimes(1);
	});

	it('reconnects immediately when the tab becomes visible', () => {
		subscribe(vi.fn());

		expect(onVisibilityChange).toBeDefined();
		onVisibilityChange?.();

		expect(mockEnsure).toHaveBeenCalledOnce();
	});

	it('does not reconnect when the tab is hidden', () => {
		vi.stubGlobal('document', {
			visibilityState: 'hidden',
			addEventListener,
			removeEventListener
		});

		subscribe(vi.fn());
		onVisibilityChange?.();

		expect(mockEnsure).not.toHaveBeenCalled();
	});

	it('cleanup unsubscribes the channel, the reconnect handler, and the visibility listener, and drops a pending refetch', () => {
		const refresh = vi.fn();
		const cleanup = subscribe(refresh);

		channelHandler()(frame('updated', 'crm', 'Company', 'crm.Company.c1'));
		cleanup();
		vi.advanceTimersByTime(REFRESH_DEBOUNCE_MS);

		expect(refresh).not.toHaveBeenCalled();
		expect(unsubDocSpy).toHaveBeenCalledTimes(1);
		expect(unsubReconnectSpy).toHaveBeenCalledTimes(1);
		expect(removeEventListener).toHaveBeenCalledWith('visibilitychange', onVisibilityChange);
	});
});
