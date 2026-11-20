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
import { subscribeDocumentRefresh, documentDependencyKey } from './documentSocket.svelte';

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

function frame(event: string, id: string): WsDocumentEvent {
	return { channel: `fanout:iam.Account:${id}`, event, payload: { id }, headers: {} };
}

/** The listener registered on the document channel. */
function channelHandler(): (event: WsDocumentEvent) => void {
	const call = mockSubscribe.mock.calls[0];
	return call[1] as (event: WsDocumentEvent) => void;
}

describe('documentDependencyKey', () => {
	it('is a stable custom dependency key per document', () => {
		expect(documentDependencyKey('iam.Account.ada')).toBe('facet:doc:iam.Account.ada');
	});
});

describe('subscribeDocumentRefresh', () => {
	it('connects and subscribes the document channel', () => {
		const refresh = vi.fn();

		subscribeDocumentRefresh({
			domain: 'iam',
			docType: 'Account',
			docId: 'iam.Account.ada',
			refresh
		});

		expect(connectSpy).toHaveBeenCalledOnce();
		expect(mockSubscribe).toHaveBeenCalledTimes(1);
		expect(mockSubscribe).toHaveBeenCalledWith(
			'/iam/Account/iam.Account.ada',
			expect.any(Function)
		);
	});

	it('refreshes on the document mutation events', () => {
		const refresh = vi.fn();
		subscribeDocumentRefresh({
			domain: 'iam',
			docType: 'Account',
			docId: 'iam.Account.ada',
			refresh
		});
		const handler = channelHandler();

		handler(frame('updated', 'iam.Account.ada'));
		handler(frame('created', 'iam.Account.ada'));
		handler(frame('deleted', 'iam.Account.ada'));

		expect(refresh).toHaveBeenCalledTimes(3);
	});

	it('ignores frames for other documents (the client dispatches every frame to every listener)', () => {
		const refresh = vi.fn();
		subscribeDocumentRefresh({
			domain: 'iam',
			docType: 'Account',
			docId: 'iam.Account.ada',
			refresh
		});

		channelHandler()(frame('updated', 'iam.Account.other'));
		channelHandler()(frame('deleted', 'iam.Account.other'));

		expect(refresh).not.toHaveBeenCalled();
	});

	it('ignores child_changed frames on the parent channel', () => {
		// An owned-child mutation names the parent in payload.id but does not
		// alter the parent's content — no document refresh.
		const refresh = vi.fn();
		subscribeDocumentRefresh({
			domain: 'iam',
			docType: 'Account',
			docId: 'iam.Account.ada',
			refresh
		});

		channelHandler()(frame('child_changed', 'iam.Account.ada'));

		expect(refresh).not.toHaveBeenCalled();
	});

	it('refreshes on reconnect (no replay while disconnected)', () => {
		const refresh = vi.fn();

		subscribeDocumentRefresh({
			domain: 'iam',
			docType: 'Account',
			docId: 'iam.Account.ada',
			refresh
		});

		expect(mockReconnect).toHaveBeenCalledWith(refresh);
	});

	it('reconnects immediately when the tab becomes visible', () => {
		subscribeDocumentRefresh({
			domain: 'iam',
			docType: 'Account',
			docId: 'iam.Account.ada',
			refresh: vi.fn()
		});

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

		subscribeDocumentRefresh({
			domain: 'iam',
			docType: 'Account',
			docId: 'iam.Account.ada',
			refresh: vi.fn()
		});
		onVisibilityChange?.();

		expect(mockEnsure).not.toHaveBeenCalled();
	});

	it('cleanup unsubscribes the channel, the reconnect handler, and the visibility listener', () => {
		const cleanup = subscribeDocumentRefresh({
			domain: 'iam',
			docType: 'Account',
			docId: 'iam.Account.ada',
			refresh: vi.fn()
		});

		cleanup();

		expect(unsubDocSpy).toHaveBeenCalledTimes(1);
		expect(unsubReconnectSpy).toHaveBeenCalledTimes(1);
		expect(removeEventListener).toHaveBeenCalledWith('visibilitychange', onVisibilityChange);
	});
});
