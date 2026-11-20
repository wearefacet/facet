// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';

// The client redirects through the session layer on a dead session. Keep the
// real `apiFetch` (the probe must exercise its refresh path) and mock only the
// redirect so the tests never touch `window.location`.
vi.mock('./session.svelte.js', async (importOriginal) => {
	const actual = await importOriginal<typeof import('./session.svelte.js')>();
	return { ...actual, redirectToLogin: vi.fn() };
});

import {
	subscribeToDocument,
	onWebSocketReconnect,
	ensureWebSocketConnected,
	getWebSocketClient
} from './websocket.svelte.js';
import { redirectToLogin, setExpiresAt } from './session.svelte.js';
import type { WsDocumentEvent } from './websocket.svelte.js';

const mockRedirect = vi.mocked(redirectToLogin);

/**
 * Unit tests for the WebSocket client's dispatch and drop-recovery surface.
 *
 * These run in Node (server project): `window` and `WebSocket` globals are
 * stubbed with a minimal fake whose instances the test drives by hand. The
 * singleton client is `disconnect()`ed after every test — that resets the
 * `started` / `everConnected` flags and clears any pending reconnect timer,
 * so tests stay order-independent.
 */

const CONNECTING = 0;
const OPEN = 1;
const CLOSED = 3;

class FakeWebSocket {
	static OPEN = OPEN;
	static CONNECTING = CONNECTING;
	static CLOSING = 2;
	static CLOSED = CLOSED;

	static instances: FakeWebSocket[] = [];

	url: string;
	readyState = CONNECTING;
	sent: string[] = [];
	onopen: (() => void) | null = null;
	onclose: ((event: { code: number }) => void) | null = null;
	onmessage: ((e: { data: unknown }) => void) | null = null;
	onerror: (() => void) | null = null;

	constructor(url: string) {
		this.url = url;
		FakeWebSocket.instances.push(this);
	}

	send(data: string) {
		this.sent.push(data);
	}

	close(code = 1006) {
		this.readyState = CLOSED;
		this.onclose?.({ code });
	}

	// ── Test drivers ───────────────────────────────────────────────────

	fireOpen() {
		this.readyState = OPEN;
		this.onopen?.();
	}

	fireMessage(frame: WsDocumentEvent) {
		this.onmessage?.({ data: JSON.stringify(frame) });
	}
}

describe('WebSocketClient — reconnect hardening', () => {
	beforeEach(() => {
		FakeWebSocket.instances = [];
		vi.stubGlobal('window', { location: { protocol: 'http:' }, dispatchEvent: vi.fn() });
		vi.stubGlobal('WebSocket', FakeWebSocket);
		// The close probe reads `/Api/iam/me`; a live session keeps the backoff.
		vi.stubGlobal(
			'fetch',
			vi.fn(async () => new Response(null, { status: 200 }))
		);
	});

	afterEach(() => {
		getWebSocketClient().disconnect();
		vi.unstubAllGlobals();
	});

	it('does not fire reconnect callbacks on the first open', () => {
		const client = getWebSocketClient();
		const onReopen = vi.fn();
		client.connect();
		FakeWebSocket.instances[0].fireOpen();

		expect(onReopen).not.toHaveBeenCalled();
	});

	it('fires reconnect callbacks on every later open', () => {
		const client = getWebSocketClient();
		const onReopen = vi.fn();
		const unsub = onWebSocketReconnect(onReopen);
		client.connect();
		FakeWebSocket.instances[0].fireOpen();
		expect(onReopen).not.toHaveBeenCalled();

		// Drop and reconnect — no waiting on the backoff timer.
		FakeWebSocket.instances[0].close();
		ensureWebSocketConnected();
		expect(FakeWebSocket.instances.length).toBe(2);
		FakeWebSocket.instances[1].fireOpen();

		expect(onReopen).toHaveBeenCalledTimes(1);
		FakeWebSocket.instances[1].close();
		ensureWebSocketConnected();
		FakeWebSocket.instances[2].fireOpen();

		expect(onReopen).toHaveBeenCalledTimes(2);
		unsub();
	});

	it('onReconnect returns an unsubscribe function', () => {
		const client = getWebSocketClient();
		const onReopen = vi.fn();
		const unsub = onWebSocketReconnect(onReopen);
		unsub();

		client.connect();
		FakeWebSocket.instances[0].fireOpen();
		FakeWebSocket.instances[0].close();
		ensureWebSocketConnected();
		FakeWebSocket.instances[1].fireOpen();

		expect(onReopen).not.toHaveBeenCalled();
	});

	it('ensureConnected is a no-op while the socket is open', () => {
		const client = getWebSocketClient();
		client.connect();
		FakeWebSocket.instances[0].fireOpen();

		expect(client.isConnected()).toBe(true);
		ensureWebSocketConnected();

		expect(FakeWebSocket.instances.length).toBe(1);
	});

	it('isConnected is false before the socket opens', () => {
		const client = getWebSocketClient();
		client.connect();

		expect(client.isConnected()).toBe(false);
	});

	it('re-sends active subscriptions on open', () => {
		const client = getWebSocketClient();
		const unsub = subscribeToDocument('/core/DocType', () => {});
		client.connect();
		FakeWebSocket.instances[0].fireOpen();

		expect(FakeWebSocket.instances[0].sent).toContainEqual(
			JSON.stringify({ action: 'subscribe', args: ['/core/DocType'] })
		);
		unsub();
	});

	it('clears the pending reconnect backoff on ensureConnected', () => {
		const client = getWebSocketClient();
		client.connect();
		FakeWebSocket.instances[0].fireOpen();
		FakeWebSocket.instances[0].close();
		// onclose scheduled a backoff retry; ensureConnected must cancel it.
		ensureWebSocketConnected();

		expect(FakeWebSocket.instances.length).toBe(2);
		expect(client.isConnected()).toBe(false);
	});
});

describe('WebSocketClient — message dispatch', () => {
	beforeEach(() => {
		FakeWebSocket.instances = [];
		vi.stubGlobal('window', { location: { protocol: 'http:' }, dispatchEvent: vi.fn() });
		vi.stubGlobal('WebSocket', FakeWebSocket);
		vi.stubGlobal(
			'fetch',
			vi.fn(async () => new Response(null, { status: 200 }))
		);
	});

	afterEach(() => {
		getWebSocketClient().disconnect();
		vi.unstubAllGlobals();
	});

	it('delivers collection events to subscribed listeners', () => {
		const client = getWebSocketClient();
		const listener = vi.fn();
		const unsub = subscribeToDocument('/core/DocType', listener);

		client.connect();
		const socket = FakeWebSocket.instances[0];
		socket.fireOpen();
		socket.fireMessage({
			channel: 'fanout:core.DocType',
			event: 'registered',
			payload: { id: 'core.DocType._abc.Invoice' },
			headers: { domain: 'core', doc_type: 'DocType' }
		});

		expect(listener).toHaveBeenCalledTimes(1);
		expect(listener.mock.calls[0][0].payload.id).toBe('core.DocType._abc.Invoice');
		unsub();
	});

	it('drops frames without a channel or event', () => {
		const client = getWebSocketClient();
		const listener = vi.fn();
		const unsub = subscribeToDocument('/core/DocType', listener);

		client.connect();
		const socket = FakeWebSocket.instances[0];
		socket.fireOpen();
		socket.onmessage?.({ data: JSON.stringify({ error: 'boom' }) });

		expect(listener).not.toHaveBeenCalled();
		unsub();
	});
});

describe('WebSocketClient — dead session', () => {
	beforeEach(() => {
		FakeWebSocket.instances = [];
		mockRedirect.mockClear();
		vi.stubGlobal('window', { location: { protocol: 'http:' }, dispatchEvent: vi.fn() });
		vi.stubGlobal('WebSocket', FakeWebSocket);
		// The probe goes through `apiFetch`; reset the module-level expiry so the
		// pre-emptive branch never masks the 401-recovery path under test.
		setExpiresAt(null);
		vi.useFakeTimers();
	});

	afterEach(() => {
		getWebSocketClient().disconnect();
		vi.useRealTimers();
		vi.unstubAllGlobals();
	});

	it('stops reconnecting and redirects on a 4401 close', async () => {
		const client = getWebSocketClient();
		client.connect();
		FakeWebSocket.instances[0].fireOpen();
		FakeWebSocket.instances[0].close(4401);

		expect(mockRedirect).toHaveBeenCalledTimes(1);
		await vi.advanceTimersByTimeAsync(60_000);
		expect(FakeWebSocket.instances.length).toBe(1);
	});

	it('stops reconnecting and redirects when the refresh fails', async () => {
		vi.stubGlobal(
			'fetch',
			vi.fn(async (input: string | URL | Request) => {
				const url = typeof input === 'string' ? input : input.toString();
				if (url === '/Api/iam/refresh') return new Response(null, { status: 401 });
				if (url === '/Api/iam/me') return new Response(null, { status: 401 });
				return new Response(null, { status: 404 });
			})
		);
		const client = getWebSocketClient();
		client.connect();
		FakeWebSocket.instances[0].fireOpen();
		FakeWebSocket.instances[0].close(1006);

		// The probe resolves in a microtask; the backoff timer is already set.
		await vi.advanceTimersByTimeAsync(0);
		expect(mockRedirect).toHaveBeenCalledTimes(1);
		await vi.advanceTimersByTimeAsync(60_000);
		expect(FakeWebSocket.instances.length).toBe(1);
	});

	it('keeps the backoff when the session is already live', async () => {
		vi.stubGlobal(
			'fetch',
			vi.fn(async () => new Response(JSON.stringify({ ok: true }), { status: 200 }))
		);
		const client = getWebSocketClient();
		client.connect();
		FakeWebSocket.instances[0].fireOpen();
		FakeWebSocket.instances[0].close(1006);

		await vi.advanceTimersByTimeAsync(0);
		expect(mockRedirect).not.toHaveBeenCalled();
		await vi.advanceTimersByTimeAsync(1000);
		expect(FakeWebSocket.instances.length).toBe(2);
	});

	it('refreshes an expired access token and keeps the backoff', async () => {
		let meCalls = 0;
		vi.stubGlobal(
			'fetch',
			vi.fn(async (input: string | URL | Request) => {
				const url = typeof input === 'string' ? input : input.toString();
				if (url === '/Api/iam/refresh') {
					return new Response(JSON.stringify({ expires_at: Math.floor(Date.now() / 1000) + 900 }), {
						status: 200
					});
				}
				if (url === '/Api/iam/me') {
					meCalls++;
					return meCalls === 1
						? new Response(null, { status: 401 })
						: new Response(JSON.stringify({ ok: true }), { status: 200 });
				}
				return new Response(null, { status: 404 });
			})
		);
		const client = getWebSocketClient();
		client.connect();
		FakeWebSocket.instances[0].fireOpen();
		FakeWebSocket.instances[0].close(1006);

		await vi.advanceTimersByTimeAsync(0);
		// The first `/Api/iam/me` 401 was recovered by a refresh and a retry.
		expect(meCalls).toBe(2);
		expect(mockRedirect).not.toHaveBeenCalled();
		await vi.advanceTimersByTimeAsync(1000);
		expect(FakeWebSocket.instances.length).toBe(2);
	});

	it('ensureConnected is a no-op after the session expired', () => {
		const client = getWebSocketClient();
		client.connect();
		FakeWebSocket.instances[0].fireOpen();
		FakeWebSocket.instances[0].close(4401);

		ensureWebSocketConnected();
		expect(FakeWebSocket.instances.length).toBe(1);
	});
});
