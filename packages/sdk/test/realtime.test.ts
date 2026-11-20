// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it, vi, afterEach } from 'vitest';
import { staticKey } from '../src/auth/provider.js';
import type { TokenProvider } from '../src/auth/provider.js';
import { createFacetClient, type FacetClient } from '../src/client.js';
import { ApiError, AuthError, NetworkError, UsageError } from '../src/errors.js';
import type {
	RealtimeHandle,
	RealtimeSocket,
	RealtimeWebSocketConstructor
} from '../src/realtime.js';

const BASE = 'https://facet.example.com';
const WS_URL = 'wss://facet.example.com/Ws';
const PATH = '/crm/Company';

/** A controllable socket double. */
class MockSocket implements RealtimeSocket {
	readyState = 0;
	sent: string[] = [];
	closeCalls: Array<[number | undefined, string | undefined]> = [];
	onopen: (() => void) | null = null;
	onmessage: ((event: { data: unknown }) => void) | null = null;
	onclose: ((event: { code: number; reason: string }) => void) | null = null;
	onerror: (() => void) | null = null;

	constructor(
		readonly url: string,
		readonly handshake?: string[] | { headers: Record<string, string> }
	) {}

	send(data: string): void {
		this.sent.push(data);
	}

	close(code?: number, reason?: string): void {
		this.closeCalls.push([code, reason]);
	}

	// ── Test controls ─────────────────────────────────────────────────

	/** The server accepted the upgrade. */
	opened(): void {
		this.readyState = 1;
		this.onopen?.();
	}

	/** The server delivered one text frame. */
	received(message: unknown): void {
		this.onmessage?.({ data: JSON.stringify(message) });
	}

	/** The server (or the network) closed the socket. */
	dropped(code: number): void {
		this.readyState = 3;
		this.onclose?.({ code, reason: '' });
	}

	sentFrames(): unknown[] {
		return this.sent.map((frame) => JSON.parse(frame) as unknown);
	}
}

interface Harness {
	ctor: ReturnType<typeof vi.fn>;
	sockets: MockSocket[];
}

function mockTransport(): Harness {
	const sockets: MockSocket[] = [];
	// A regular function: the SDK dials it with `new`.
	const ctor = vi.fn(function (
		this: unknown,
		url: string,
		arg?: string[] | { headers: Record<string, string> }
	) {
		const socket = new MockSocket(url, arg);
		sockets.push(socket);
		return socket;
	});
	return { ctor, sockets };
}

function clientWith(auth: TokenProvider): FacetClient {
	return createFacetClient({ baseUrl: BASE, auth, fetchImpl: vi.fn() });
}

/** Builds a handle on an injected transport. */
function handleOn(harness: Harness, auth: TokenProvider = staticKey('k')): RealtimeHandle {
	return clientWith(auth).realtime({
		WebSocket: harness.ctor as unknown as RealtimeWebSocketConstructor
	});
}

/** A provider with a refresh hook that records its calls. */
function refreshableProvider(): TokenProvider & { refreshCalls: number[] } {
	const provider = {
		refreshCalls: [] as number[],
		getToken: () => Promise.resolve('tok_1'),
		refreshOn401: () => {
			provider.refreshCalls.push(provider.refreshCalls.length + 1);
			return Promise.resolve('tok_2');
		}
	};
	return provider;
}

/**
 * The dial is async: the token read suspends before the socket exists, and
 * the dial settles when the test opens the socket. A few microtask ticks
 * settle the construction chain.
 */
async function settle(): Promise<void> {
	for (let i = 0; i < 10; i++) {
		await Promise.resolve();
	}
}

afterEach(() => {
	vi.unstubAllGlobals();
	vi.useRealTimers();
});

describe('handshake', () => {
	it('the browser transport offers the subprotocol list with the token', async () => {
		const { ctor, sockets } = mockTransport();
		const rt = clientWith(staticKey('fct_key')).realtime();

		vi.stubGlobal('WebSocket', ctor);
		rt.ensureConnected().catch(() => {});
		await settle();
		expect(sockets).toHaveLength(1);
		expect(sockets[0]?.url).toBe(WS_URL);
		expect(sockets[0]?.handshake).toEqual(['facet-ws-v1', 'fct_key']);
	});

	it('an injected transport sends the Authorization header on the upgrade', async () => {
		const { ctor, sockets } = mockTransport();
		const rt = handleOn({ ctor, sockets }, staticKey('fct_key'));

		rt.ensureConnected().catch(() => {});
		await settle();
		expect(sockets[0]?.url).toBe(WS_URL);
		expect(sockets[0]?.handshake).toEqual({ headers: { authorization: 'Bearer fct_key' } });
	});

	it('a provider without a token refuses before the dial', async () => {
		const { ctor } = mockTransport();
		const rt = clientWith({ getToken: () => Promise.resolve(null) }).realtime({
			WebSocket: ctor as unknown as RealtimeWebSocketConstructor
		});
		await expect(rt.ensureConnected()).rejects.toBeInstanceOf(AuthError);
		expect(ctor).not.toHaveBeenCalled();
	});

	it('https maps to wss and http maps to ws', async () => {
		const { ctor, sockets } = mockTransport();
		const facet = createFacetClient({
			baseUrl: 'http://facet.example.com',
			auth: staticKey('k'),
			fetchImpl: vi.fn()
		});
		facet
			.realtime({ WebSocket: ctor as unknown as RealtimeWebSocketConstructor })
			.ensureConnected()
			.catch(() => {});
		await settle();
		expect(sockets[0]?.url).toBe('ws://facet.example.com/Ws');
	});

	it('the injected transport is used when globalThis.WebSocket is absent', async () => {
		vi.stubGlobal('WebSocket', undefined);
		const { ctor, sockets } = mockTransport();
		const rt = handleOn({ ctor, sockets });
		rt.ensureConnected().catch(() => {});
		await settle();
		expect(sockets).toHaveLength(1);

		const bare = clientWith(staticKey('k')).realtime();
		await expect(bare.ensureConnected()).rejects.toBeInstanceOf(UsageError);
	});
});

describe('subscribe and unsubscribe frames', () => {
	it('sends the subscribe frame on open and the unsubscribe frame on off', async () => {
		const { ctor, sockets } = mockTransport();
		const rt = handleOn({ ctor, sockets });
		const frames: unknown[] = [];
		const promise = rt.subscribe(PATH, (frame) => frames.push(frame));
		await settle();

		const socket = sockets[0] as MockSocket;
		socket.opened();
		expect(socket.sentFrames()).toEqual([{ action: 'subscribe', args: [PATH] }]);

		// The server sends no subscribe ack; a matching data frame settles
		// the promise.
		socket.received({
			channel: 'fanout:crm.Company:created',
			event: 'created',
			payload: { id: 'crm.Company.c1' },
			headers: { domain: 'crm', doc_type: 'Company' }
		});
		const off = await promise;
		expect(frames).toHaveLength(1);

		off();
		expect(socket.sentFrames()[1]).toEqual({ action: 'unsubscribe', args: [PATH] });
	});

	it('does not send the unsubscribe frame while another handler stays', async () => {
		const { ctor, sockets } = mockTransport();
		const rt = handleOn({ ctor, sockets });
		const first = rt.subscribe(PATH, () => {});
		const second = rt.subscribe(PATH, () => {});
		await settle();
		const socket = sockets[0] as MockSocket;
		socket.opened();
		socket.received({
			channel: 'fanout:crm.Company:created',
			event: 'created',
			payload: { id: 'crm.Company.c1' },
			headers: {}
		});
		(await first)();
		const unsubscribeSent = socket
			.sentFrames()
			.some((frame) => (frame as { action: string }).action === 'unsubscribe');
		expect(unsubscribeSent).toBe(false);
		(await second)();
		expect(socket.sentFrames().at(-1)).toEqual({ action: 'unsubscribe', args: [PATH] });
	});

	it('sends the subscribe frame at once when the socket is already open', async () => {
		const { ctor, sockets } = mockTransport();
		const rt = handleOn({ ctor, sockets });
		rt.ensureConnected().catch(() => {});
		await settle();
		const socket = sockets[0] as MockSocket;
		socket.opened();
		socket.sent.length = 0;

		const promise = rt.subscribe('/crm/Invoice/inv_1', () => {});
		await settle();
		expect(socket.sentFrames()).toEqual([{ action: 'subscribe', args: ['/crm/Invoice/inv_1'] }]);
		socket.received({
			channel: 'fanout:crm.Invoice:inv_1:updated',
			event: 'updated',
			payload: { id: 'crm.Invoice.inv_1' },
			headers: {}
		});
		await expect(promise).resolves.toBeTypeOf('function');
	});

	it('dispatches frames to the matching subscription only', async () => {
		const { ctor, sockets } = mockTransport();
		const rt = handleOn({ ctor, sockets });
		const companyFrames: unknown[] = [];
		const invoiceFrames: unknown[] = [];
		rt.subscribe('/crm/Company', (frame) => companyFrames.push(frame));
		rt.subscribe('/crm/Invoice/inv_1', (frame) => invoiceFrames.push(frame));
		await settle();
		const socket = sockets[0] as MockSocket;
		socket.opened();

		socket.received({
			channel: 'fanout:crm.Invoice:inv_1:updated',
			event: 'updated',
			payload: { id: 'crm.Invoice.inv_1' },
			headers: {}
		});
		expect(companyFrames).toHaveLength(0);
		expect(invoiceFrames).toHaveLength(1);

		socket.received({
			channel: 'fanout:crm.Company:c1:updated',
			event: 'updated',
			payload: { id: 'crm.Company.c1' },
			headers: {}
		});
		expect(companyFrames).toHaveLength(1);
		expect(invoiceFrames).toHaveLength(1);
	});

	it('does not confuse a doctype whose name extends another', async () => {
		const { ctor, sockets } = mockTransport();
		const rt = handleOn({ ctor, sockets });
		const frames: unknown[] = [];
		rt.subscribe('/crm/Company', (frame) => frames.push(frame));
		await settle();
		const socket = sockets[0] as MockSocket;
		socket.opened();
		socket.received({
			channel: 'fanout:crm.CompanyX:c1:updated',
			event: 'updated',
			payload: { id: 'crm.CompanyX.c1' },
			headers: {}
		});
		expect(frames).toHaveLength(0);
	});
});

describe('reconnect', () => {
	it('re-sends every active subscription, then fires the reconnect handlers', async () => {
		vi.useFakeTimers();
		const { ctor, sockets } = mockTransport();
		const rt = handleOn({ ctor, sockets });
		const order: string[] = [];
		rt.onReconnect(() => order.push('reconnect'));

		const promise = rt.subscribe(PATH, () => order.push('frame'));
		await settle();
		const first = sockets[0] as MockSocket;
		first.opened();
		// Settle the subscription so the test holds `off`.
		first.received({
			channel: 'fanout:crm.Company:created',
			event: 'created',
			payload: { id: 'crm.Company.c1' },
			headers: {}
		});
		await promise;
		order.length = 0;

		first.dropped(1006);
		await vi.advanceTimersByTimeAsync(1_000);
		expect(sockets).toHaveLength(2);

		const second = sockets[1] as MockSocket;
		second.opened();
		expect(order).toEqual(['reconnect']);
		expect(second.sentFrames()).toEqual([{ action: 'subscribe', args: [PATH] }]);
	});

	it('backs off with a cap', async () => {
		vi.useFakeTimers();
		const { ctor, sockets } = mockTransport();
		const rt = handleOn({ ctor, sockets });
		rt.ensureConnected().catch(() => {});
		await settle();
		(sockets[0] as MockSocket).opened();
		(sockets[0] as MockSocket).dropped(1006);
		await vi.advanceTimersByTimeAsync(999);
		expect(sockets).toHaveLength(1);
		await vi.advanceTimersByTimeAsync(1);
		expect(sockets).toHaveLength(2);

		(sockets[1] as MockSocket).opened();
		(sockets[1] as MockSocket).dropped(1006);
		// A successful open resets the backoff, like the frontend handle:
		// the next retry waits the base delay again.
		await vi.advanceTimersByTimeAsync(999);
		expect(sockets).toHaveLength(2);
		await vi.advanceTimersByTimeAsync(1);
		expect(sockets).toHaveLength(3);
	});

	it('pulls a fresh token from the provider on every reconnect', async () => {
		vi.useFakeTimers();
		const tokens = ['tok_a', 'tok_b'];
		let calls = 0;
		const provider: TokenProvider = {
			getToken: () => Promise.resolve(tokens[calls++] ?? 'tok_z')
		};
		const { ctor, sockets } = mockTransport();
		const rt = handleOn({ ctor, sockets }, provider);
		rt.ensureConnected().catch(() => {});
		await settle();
		expect(sockets[0]?.handshake).toEqual({ headers: { authorization: 'Bearer tok_a' } });

		(sockets[0] as MockSocket).dropped(1006);
		await vi.advanceTimersByTimeAsync(1_000);
		expect(sockets[1]?.handshake).toEqual({ headers: { authorization: 'Bearer tok_b' } });
	});
});

describe('close codes', () => {
	it('4401 refreshes the token once, reconnects, and fails on the next 4401', async () => {
		const { ctor, sockets } = mockTransport();
		const provider = refreshableProvider();
		const rt = handleOn({ ctor, sockets }, provider);
		const promise = rt.subscribe(PATH, () => {});
		await settle();
		const first = sockets[0] as MockSocket;
		first.opened();
		first.dropped(4401);
		await settle();

		expect(provider.refreshCalls).toEqual([1]);
		expect(sockets).toHaveLength(2);

		// The refreshed credential is refused too: stop with AuthError.
		(sockets[1] as MockSocket).opened();
		(sockets[1] as MockSocket).dropped(4401);
		await settle();
		expect(provider.refreshCalls).toEqual([1]);
		expect(sockets).toHaveLength(2);
		await expect(promise).rejects.toBeInstanceOf(AuthError);

		// The handle is terminal: no further dial.
		await expect(rt.ensureConnected()).rejects.toBeInstanceOf(AuthError);
		expect(sockets).toHaveLength(2);
	});

	it('4401 without a refresh capability fails at once', async () => {
		const { ctor, sockets } = mockTransport();
		const rt = handleOn({ ctor, sockets });
		const promise = rt.subscribe(PATH, () => {});
		await settle();
		(sockets[0] as MockSocket).opened();
		(sockets[0] as MockSocket).dropped(4401);
		await expect(promise).rejects.toBeInstanceOf(AuthError);
		expect(sockets).toHaveLength(1);
	});

	// B-335: the opener awaiting `ensureConnected` must receive the actionable
	// 4401 AuthError, not the opaque network-drop error.
	it('a dial refused with 4401 rejects ensureConnected with the auth error', async () => {
		const { ctor, sockets } = mockTransport();
		const rt = handleOn({ ctor, sockets });
		const promise = rt.ensureConnected();
		await settle();
		(sockets[0] as MockSocket).dropped(4401);
		await expect(promise).rejects.toBeInstanceOf(AuthError);
		await expect(promise).rejects.toThrow(/static fct_ keys/);
		expect(sockets).toHaveLength(1);
	});

	it('a dial refused with 4403 rejects ensureConnected with the auth error', async () => {
		const { ctor, sockets } = mockTransport();
		const rt = handleOn({ ctor, sockets });
		const promise = rt.ensureConnected();
		await settle();
		(sockets[0] as MockSocket).dropped(4403);
		await expect(promise).rejects.toBeInstanceOf(AuthError);
		expect(sockets).toHaveLength(1);
	});

	it('4403 fails with no retry and no refresh', async () => {
		const { ctor, sockets } = mockTransport();
		const provider = refreshableProvider();
		const rt = handleOn({ ctor, sockets }, provider);
		const promise = rt.subscribe(PATH, () => {});
		await settle();
		(sockets[0] as MockSocket).opened();
		(sockets[0] as MockSocket).dropped(4403);
		await expect(promise).rejects.toBeInstanceOf(AuthError);
		expect(provider.refreshCalls).toEqual([]);
		expect(sockets).toHaveLength(1);
	});
});

describe('in-band error frames', () => {
	it('an RBAC denial rejects the subscription and keeps the socket open', async () => {
		const { ctor, sockets } = mockTransport();
		const rt = handleOn({ ctor, sockets });
		const socketRef = { current: undefined as MockSocket | undefined };
		const promise = rt.subscribe(PATH, () => {});
		await settle();
		const socket = sockets[0] as MockSocket;
		socketRef.current = socket;
		socket.opened();

		socket.received({ error: 'not found or forbidden', path: PATH });
		await expect(promise).rejects.toBeInstanceOf(ApiError);
		expect(socket.closeCalls).toHaveLength(0);
		// The socket stays open: a later subscription rides the same socket.
		const retry = rt.subscribe('/crm/Invoice/inv_1', () => {});
		socket.received({
			channel: 'fanout:crm.Invoice:inv_1:created',
			event: 'created',
			payload: { id: 'crm.Invoice.inv_1' },
			headers: {}
		});
		await expect(retry).resolves.toBeTypeOf('function');
	});

	it('the over-cap error frame rejects without a close', async () => {
		const { ctor, sockets } = mockTransport();
		const rt = handleOn({ ctor, sockets });
		const promise = rt.subscribe(PATH, () => {});
		await settle();
		const socket = sockets[0] as MockSocket;
		socket.opened();
		socket.received({ error: 'too many subscribers for this collection', path: PATH });
		await expect(promise).rejects.toThrow(/too many subscribers/);
		expect(socket.closeCalls).toHaveLength(0);
	});

	it('an error frame without a path leaves subscriptions alone', async () => {
		const { ctor, sockets } = mockTransport();
		const rt = handleOn({ ctor, sockets });
		const promise = rt.subscribe(PATH, () => {});
		await settle();
		const socket = sockets[0] as MockSocket;
		socket.opened();
		socket.received({ error: "Unknown action 'frobnicate'" });
		socket.received({ error: 'Invalid JSON frame' });
		socket.received({
			channel: 'fanout:crm.Company:created',
			event: 'created',
			payload: { id: 'crm.Company.c1' },
			headers: {}
		});
		await expect(promise).resolves.toBeTypeOf('function');
	});

	it('a non-JSON frame is ignored', async () => {
		const { ctor, sockets } = mockTransport();
		const rt = handleOn({ ctor, sockets });
		rt.subscribe(PATH, () => {});
		await settle();
		const socket = sockets[0] as MockSocket;
		socket.opened();
		expect(() => socket.onmessage?.({ data: 'not json' })).not.toThrow();
		expect(() => socket.onmessage?.({ data: 42 })).not.toThrow();
	});
});

describe('close', () => {
	it('close stops the handle, rejects pending subscribes, and clears the socket', async () => {
		const { ctor, sockets } = mockTransport();
		const rt = handleOn({ ctor, sockets });
		const promise = rt.subscribe(PATH, () => {});
		await settle();
		const socket = sockets[0] as MockSocket;
		socket.opened();

		rt.close();
		await expect(promise).rejects.toBeInstanceOf(NetworkError);
		expect(socket.closeCalls).toHaveLength(1);
		await expect(rt.subscribe(PATH, () => {})).rejects.toBeInstanceOf(UsageError);
		await expect(rt.ensureConnected()).rejects.toBeInstanceOf(UsageError);
	});

	it('a drop after close does not reconnect', async () => {
		vi.useFakeTimers();
		const { ctor, sockets } = mockTransport();
		const rt = handleOn({ ctor, sockets });
		rt.ensureConnected().catch(() => {});
		await settle();
		const socket = sockets[0] as MockSocket;
		socket.opened();
		rt.close();
		socket.dropped(1006);
		await vi.advanceTimersByTimeAsync(60_000);
		expect(sockets).toHaveLength(1);
	});
});

describe('onRefusal', () => {
	it('an in-band error frame fires the refusal handlers with the rejected error', async () => {
		const { ctor, sockets } = mockTransport();
		const rt = handleOn({ ctor, sockets });
		const refusals = vi.fn();
		rt.onRefusal(refusals);
		const promise = rt.subscribe(PATH, () => {});
		await settle();
		const socket = sockets[0] as MockSocket;
		socket.opened();
		socket.received({ error: 'not found or forbidden', path: PATH });
		const rejected = await promise.catch((error: unknown) => error);
		expect(rejected).toBeInstanceOf(ApiError);
		expect(refusals).toHaveBeenCalledTimes(1);
		expect(refusals.mock.calls[0]?.[0]).toBe(rejected);
	});

	it('a 4403 close fires the refusal handlers with the auth error', async () => {
		const { ctor, sockets } = mockTransport();
		const rt = handleOn({ ctor, sockets });
		const refusals = vi.fn();
		rt.onRefusal(refusals);
		const promise = rt.subscribe(PATH, () => {});
		await settle();
		(sockets[0] as MockSocket).opened();
		(sockets[0] as MockSocket).dropped(4403);
		const rejected = await promise.catch((error: unknown) => error);
		expect(rejected).toBeInstanceOf(AuthError);
		expect(refusals).toHaveBeenCalledTimes(1);
		expect(refusals.mock.calls[0]?.[0]).toBe(rejected);
	});

	it('a terminal refusal fires the handlers once, for every path it takes down', async () => {
		const { ctor, sockets } = mockTransport();
		const rt = handleOn({ ctor, sockets });
		const refusals = vi.fn();
		rt.onRefusal(refusals);
		const first = rt.subscribe(PATH, () => {});
		const second = rt.subscribe('/hr/Person', () => {});
		await settle();
		(sockets[0] as MockSocket).opened();
		(sockets[0] as MockSocket).dropped(4403);
		await expect(first).rejects.toBeInstanceOf(AuthError);
		await expect(second).rejects.toBeInstanceOf(AuthError);
		expect(refusals).toHaveBeenCalledTimes(1);
	});

	it('a refused dial fires the handlers even with no subscriptions', async () => {
		const { ctor, sockets } = mockTransport();
		const rt = handleOn({ ctor, sockets });
		const refusals = vi.fn();
		rt.onRefusal(refusals);
		const promise = rt.ensureConnected();
		await settle();
		(sockets[0] as MockSocket).dropped(4403);
		await expect(promise).rejects.toBeInstanceOf(AuthError);
		expect(refusals).toHaveBeenCalledTimes(1);
	});

	it('the unsubscribe removes the handler', async () => {
		const { ctor, sockets } = mockTransport();
		const rt = handleOn({ ctor, sockets });
		const refusals = vi.fn();
		const off = rt.onRefusal(refusals);
		off();
		const promise = rt.subscribe(PATH, () => {});
		await settle();
		(sockets[0] as MockSocket).opened();
		(sockets[0] as MockSocket).dropped(4403);
		await expect(promise).rejects.toBeInstanceOf(AuthError);
		expect(refusals).not.toHaveBeenCalled();
	});

	it('a recoverable drop is not a refusal', async () => {
		const { ctor, sockets } = mockTransport();
		const rt = handleOn({ ctor, sockets });
		const refusals = vi.fn();
		rt.onRefusal(refusals);
		const promise = rt.subscribe(PATH, () => {});
		await settle();
		(sockets[0] as MockSocket).opened();
		(sockets[0] as MockSocket).dropped(1006);
		// A drop keeps the subscription pending for the resend on reconnect;
		// close the handle to settle it with the plain network error.
		rt.close();
		await expect(promise).rejects.toBeInstanceOf(NetworkError);
		expect(refusals).not.toHaveBeenCalled();
	});
});
