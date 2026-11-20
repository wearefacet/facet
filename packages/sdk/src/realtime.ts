// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { ApiError, AuthError, NetworkError, UsageError } from './errors.js';
import type { TokenProvider } from './auth/provider.js';

/** One change frame from the real-time bridge. A hint, never document state. */
export interface WsFrame {
	/** The fanout channel, e.g. `fanout:crm.Company:crm.Company.abc:updated`. */
	channel: string;
	/** The event name: `created`, `updated`, `deleted`, `child_changed`, or others. */
	event: string;
	/** The document payload. At minimum `{ id }`. Never full content. */
	payload: Record<string, unknown>;
	/** Mutation metadata headers. */
	headers: {
		mutation_id?: string;
		actioner_id?: string;
		domain?: string;
		doc_type?: string;
	};
}

/** Receives the frames of one subscription. */
export type FrameHandler = (frame: WsFrame) => void;

/** Runs after the socket re-open following a drop. */
export type ReconnectHandler = () => void;

/** Runs when the server refuses a subscription or the socket credential. */
export type RefusalHandler = (error: ApiError | UsageError) => void;

/** One live socket. A structural subset of the DOM `WebSocket`. */
export interface RealtimeSocket {
	send(data: string): void;
	close(code?: number, reason?: string): void;
	onopen: (() => void) | null;
	onmessage: ((event: { data: unknown }) => void) | null;
	onclose: ((event: { code: number; reason: string }) => void) | null;
	onerror: (() => void) | null;
}

/**
 * A WebSocket constructor. `globalThis.WebSocket` fits the first form. A
 * header-capable transport, such as the `ws` package on Node, fits the
 * second — the SDK uses it to send the `Authorization` header on the
 * upgrade request.
 */
export interface RealtimeWebSocketConstructor {
	new (url: string, protocols?: string[]): RealtimeSocket;
	new (url: string, options: { headers: Record<string, string> }): RealtimeSocket;
}

/** Options for `facet.realtime()`. */
export interface RealtimeOptions {
	/**
	 * The socket transport. The module uses `globalThis.WebSocket` when this
	 * is absent. On a runtime without a global WebSocket, such as Node 20,
	 * pass a header-capable constructor; the SDK then sends the credential
	 * as an `Authorization` header instead of a subprotocol entry.
	 */
	WebSocket?: RealtimeWebSocketConstructor;
}

/** The real-time handle of one client. Created with `facet.realtime()`. */
export interface RealtimeHandle {
	/**
	 * Subscribes one resource path and registers a handler for its frames.
	 *
	 * The path follows the server grammar: `/domain/Doctype` for a
	 * collection, `/domain/Doctype/:id` for a document, and
	 * `/domain/Doctype/:id/:rel/:child` for a nested child.
	 *
	 * The server sends no subscribe acknowledgement, so the promise settles
	 * on the first server message the handle can trace back to the path: an
	 * in-band error frame rejects it (RBAC denial, over-cap), a matching
	 * data frame resolves it. On a channel that stays quiet the promise
	 * stays pending — do not await it when that matters; the handler
	 * receives frames regardless. The server resolves nested child paths to
	 * channels a client cannot recompute, so such a subscription receives
	 * every frame; filter in the handler.
	 */
	subscribe(path: string, handler: FrameHandler): Promise<() => void>;

	/** Registers a callback that runs after every re-open that follows a drop. */
	onReconnect(handler: ReconnectHandler): () => void;

	/**
	 * Registers a callback that runs when the server refuses the realtime
	 * traffic: an in-band error frame rejects one subscription, a `4401` /
	 * `4403` close or a refused dial ends the handle. The handler receives
	 * the same error the `subscribe()` promise rejects with — an `ApiError`
	 * (an `AuthError` for credential refusals) or a `UsageError` — once per
	 * refusal event, however many subscriptions were pending. The returned
	 * function removes the handler. A recoverable drop is not a refusal.
	 */
	onRefusal(handler: RefusalHandler): () => void;

	/**
	 * Opens the socket now when it is down. Resolves when the socket is
	 * open. Safe to call several times — later calls join the first.
	 */
	ensureConnected(): Promise<void>;

	/** Closes the socket, drops every subscription, and stops the handle. */
	close(): void;
}

const WS_PATH = '/Ws';
/** The subprotocol the backend answers on the browser transport. */
const SUBPROTOCOL = 'facet-ws-v1';
const RECONNECT_BASE_MS = 1_000;
const RECONNECT_FACTOR = 1.5;
const RECONNECT_MAX_MS = 10_000;

interface Pending {
	resolve(): void;
	reject(error: ApiError | UsageError): void;
}

/** One subscription path: its handlers, its settlement promises, its channel. */
interface PathEntry {
	path: string;
	handlers: Set<FrameHandler>;
	pending: Set<Pending>;
	/** The fanout channel of the path, when the client can compute it. */
	baseChannel: string | null;
	/** True when the handle cannot match frames by channel. */
	receiveAll: boolean;
	/** The socket generation the subscribe frame last rode. */
	sentOn: number;
}

/**
 * Computes the fanout channel of a path, with the same grammar as the
 * server's `Websocket::SubscriptionResolver.resolve_channel`. Returns
 * `nested` for paths deeper than three segments: the server resolves those
 * to the target child's own channel, which the client cannot recompute.
 * Returns `null` for a path the server refuses anyway.
 */
function baseChannelOf(path: string): { channel: string; nested: boolean } | null {
	const segments = path.split('/').filter((segment) => segment !== '');
	if (segments.length < 2) {
		return null;
	}
	if (segments.length === 2) {
		return { channel: `fanout:${segments[0]}.${segments[1]}`, nested: false };
	}
	if (segments.length % 2 === 0) {
		return null;
	}
	return {
		channel: `fanout:${segments[0]}.${segments[1]}:${segments[2]}`,
		nested: segments.length > 3
	};
}

/** A frame matches a base channel on equality or on an `:event` suffix. */
function channelMatches(base: string, channel: string): boolean {
	return channel === base || channel.startsWith(`${base}:`);
}

function wsUrlOf(baseUrl: string): string {
	const url = new URL(WS_PATH, baseUrl);
	url.protocol = url.protocol === 'https:' || url.protocol === 'wss:' ? 'wss:' : 'ws:';
	return url.toString();
}

function globalWebSocket(): RealtimeWebSocketConstructor | undefined {
	// The DOM constructor's second parameter differs from the structural
	// contract, so the lookup rides `unknown` first.
	const scope = globalThis as unknown as { WebSocket?: RealtimeWebSocketConstructor };
	return scope.WebSocket;
}

function errorMessage(error: unknown): string {
	return error instanceof Error ? error.message : String(error);
}

/** Creates the real-time handle of one client. One socket, many subscriptions. */
export function createRealtimeHandle(
	baseUrl: string,
	auth: TokenProvider | undefined,
	options: RealtimeOptions
): RealtimeHandle {
	return new RealtimeHandleImpl(baseUrl, auth, options);
}

class RealtimeHandleImpl implements RealtimeHandle {
	private readonly paths = new Map<string, PathEntry>();
	private readonly reconnectListeners = new Set<ReconnectHandler>();
	private readonly refusalListeners = new Set<RefusalHandler>();
	private readonly injectedTransport: boolean;
	private readonly transportCtor: RealtimeWebSocketConstructor | undefined;
	private socket: RealtimeSocket | null = null;
	private state: 'idle' | 'connecting' | 'open' = 'idle';
	/** The dial in progress: from the first `ensureConnected` until the socket opens or closes. */
	private opening: Promise<void> | null = null;
	private dialSettle: {
		resolve: () => void;
		reject: (error: ApiError | UsageError) => void;
	} | null = null;
	private timer: ReturnType<typeof setTimeout> | null = null;
	private delay = RECONNECT_BASE_MS;
	private generation = 0;
	private everConnected = false;
	private refreshedSinceOpen = false;
	private closedByCaller = false;
	private terminalError: ApiError | UsageError | null = null;

	constructor(
		private readonly baseUrl: string,
		private readonly auth: TokenProvider | undefined,
		options: RealtimeOptions
	) {
		this.injectedTransport = options.WebSocket !== undefined;
		this.transportCtor = options.WebSocket;
	}

	subscribe(path: string, handler: FrameHandler): Promise<() => void> {
		if (this.terminalError !== null) {
			return Promise.reject(this.terminalError);
		}
		if (this.closedByCaller) {
			return Promise.reject(
				new UsageError('The real-time handle is closed. Create a new one with facet.realtime().')
			);
		}
		const entry = this.entryFor(path);
		entry.handlers.add(handler);
		return new Promise<() => void>((resolve, reject) => {
			const pending: Pending = {
				resolve: () => {
					entry.pending.delete(pending);
					resolve(() => this.unsubscribe(path, handler));
				},
				reject: (error) => {
					entry.pending.delete(pending);
					entry.handlers.delete(handler);
					if (entry.handlers.size === 0 && entry.pending.size === 0) {
						this.paths.delete(path);
					}
					reject(error);
				}
			};
			entry.pending.add(pending);
			this.ensureConnected().then(
				() => {
					// `handleOpen` sends the frame for every entry when the socket
					// opens; send here only when the socket was already open.
					if (this.state === 'open' && entry.sentOn !== this.generation) {
						this.sendSubscribe(entry);
					}
				},
				(error: ApiError | UsageError) => {
					// A transient dial failure keeps the subscription pending: the
					// resend on reconnect covers it. A refusal — no credential, no
					// transport, a closed handle — rejects it.
					if (
						error instanceof NetworkError &&
						this.terminalError === null &&
						!this.closedByCaller
					) {
						return;
					}
					pending.reject(error);
				}
			);
		});
	}

	onReconnect(handler: ReconnectHandler): () => void {
		this.reconnectListeners.add(handler);
		return () => {
			this.reconnectListeners.delete(handler);
		};
	}

	onRefusal(handler: RefusalHandler): () => void {
		this.refusalListeners.add(handler);
		return () => {
			this.refusalListeners.delete(handler);
		};
	}

	ensureConnected(): Promise<void> {
		if (this.terminalError !== null) {
			return Promise.reject(this.terminalError);
		}
		if (this.closedByCaller) {
			return Promise.reject(
				new UsageError('The real-time handle is closed. Create a new one with facet.realtime().')
			);
		}
		if (this.state === 'open') {
			return Promise.resolve();
		}
		if (this.opening !== null) {
			return this.opening;
		}
		// An explicit request should not wait on the backoff timer.
		if (this.timer !== null) {
			clearTimeout(this.timer);
			this.timer = null;
		}
		return this.open();
	}

	close(): void {
		this.closedByCaller = true;
		if (this.timer !== null) {
			clearTimeout(this.timer);
			this.timer = null;
		}
		const closed = new NetworkError('The real-time handle was closed.');
		for (const entry of this.paths.values()) {
			for (const pending of [...entry.pending]) {
				pending.reject(closed);
			}
		}
		this.paths.clear();
		this.reconnectListeners.clear();
		this.refusalListeners.clear();
		const socket = this.socket;
		const wasOpen = this.state === 'open';
		this.socket = null;
		this.state = 'idle';
		if (socket !== null) {
			if (wasOpen) {
				try {
					socket.send(JSON.stringify({ action: 'unsubscribe', args: ['*'] }));
				} catch {
					// The socket is going away anyway.
				}
			}
			try {
				socket.close(1000, 'client closed');
			} catch {
				// Already closed.
			}
		}
	}

	// ── Internals ────────────────────────────────────────────────────────

	private entryFor(path: string): PathEntry {
		const existing = this.paths.get(path);
		if (existing !== undefined) {
			return existing;
		}
		const base = baseChannelOf(path);
		const entry: PathEntry = {
			path,
			handlers: new Set(),
			pending: new Set(),
			baseChannel: base?.channel ?? null,
			receiveAll: base === null || base.nested,
			sentOn: -1
		};
		this.paths.set(path, entry);
		return entry;
	}

	private open(): Promise<void> {
		if (this.state === 'open') {
			return Promise.resolve();
		}
		if (this.opening !== null) {
			return this.opening;
		}
		this.state = 'connecting';
		let resolveDial!: () => void;
		let rejectDial!: (error: ApiError | UsageError) => void;
		const dial = new Promise<void>((resolve, reject) => {
			resolveDial = resolve;
			rejectDial = reject;
		});
		this.dialSettle = { resolve: resolveDial, reject: rejectDial };
		const construct = async (): Promise<void> => {
			const Ctor = this.transportCtor ?? globalWebSocket();
			if (Ctor === undefined) {
				throw new UsageError(
					'No WebSocket transport is available. Pass one with realtime({ WebSocket }).'
				);
			}
			let token: string | null = null;
			if (this.auth !== undefined) {
				// Pulled at connect and on every reconnect — a fresh token
				// rides the next handshake.
				token = await this.auth.getToken();
				if (token === null) {
					throw new AuthError(
						'No credential is available for the real-time connection. Provide a token provider that returns a bearer token.'
					);
				}
			}
			const url = wsUrlOf(this.baseUrl);
			this.generation += 1;
			let socket: RealtimeSocket;
			if (this.injectedTransport) {
				// A header-capable transport carries the credential on the
				// upgrade request. Static `fct_` keys are accepted there.
				const headers: Record<string, string> = {};
				if (token !== null) {
					headers['authorization'] = `Bearer ${token}`;
				}
				socket = new Ctor(url, { headers });
			} else {
				// The browser transport carries the credential as a
				// subprotocol entry; the backend answers `facet-ws-v1`.
				socket = token !== null ? new Ctor(url, [SUBPROTOCOL, token]) : new Ctor(url);
			}
			this.socket = socket;
			socket.onopen = () => this.handleOpen();
			socket.onmessage = (event) => this.handleMessage(event.data);
			socket.onclose = (event) => this.handleClose(event.code);
			socket.onerror = () => {
				// The close event follows and drives the reconnect.
			};
		};
		void construct().then(
			() => {
				// Constructed. The dial settles when the socket opens
				// (`handleOpen`) or when it closes first (`handleClose`).
			},
			(error: unknown) => {
				this.dialSettle = null;
				this.opening = null;
				this.state = 'idle';
				rejectDial(
					error instanceof ApiError || error instanceof UsageError
						? error
						: new NetworkError(errorMessage(error))
				);
			}
		);
		this.opening = dial;
		return dial;
	}

	private handleOpen(): void {
		if (this.closedByCaller) {
			this.socket?.close();
			this.socket = null;
			return;
		}
		this.state = 'open';
		this.delay = RECONNECT_BASE_MS;
		const settle = this.dialSettle;
		this.dialSettle = null;
		this.opening = null;
		settle?.resolve();
		// The server delivers no replay, so every active subscription is
		// re-sent before the reconnect handlers run.
		for (const entry of this.paths.values()) {
			this.sendSubscribe(entry);
		}
		if (this.everConnected) {
			for (const listener of [...this.reconnectListeners]) {
				listener();
			}
		}
		this.everConnected = true;
	}

	private sendSubscribe(entry: PathEntry): void {
		this.sendFrame({ action: 'subscribe', args: [entry.path] });
		entry.sentOn = this.generation;
	}

	private handleMessage(data: unknown): void {
		const text = typeof data === 'string' ? data : String(data ?? '');
		let msg: unknown;
		try {
			msg = JSON.parse(text);
		} catch {
			return;
		}
		if (typeof msg !== 'object' || msg === null) {
			return;
		}
		const record = msg as Record<string, unknown>;
		if (typeof record['error'] === 'string') {
			// In-band error frame. The socket stays open; only the refused
			// subscription settles.
			const path = typeof record['path'] === 'string' ? record['path'] : null;
			if (path !== null) {
				this.rejectPath(
					path,
					new ApiError(`The server refused the subscription to ${path}: ${record['error']}`, 0)
				);
			}
			return;
		}
		if (typeof record['channel'] !== 'string' || typeof record['event'] !== 'string') {
			return;
		}
		const frame: WsFrame = {
			channel: record['channel'],
			event: record['event'],
			payload:
				typeof record['payload'] === 'object' && record['payload'] !== null
					? (record['payload'] as Record<string, unknown>)
					: {},
			headers:
				typeof record['headers'] === 'object' && record['headers'] !== null
					? (record['headers'] as WsFrame['headers'])
					: {}
		};
		for (const entry of [...this.paths.values()]) {
			if (!this.entryReceives(entry, frame.channel)) {
				continue;
			}
			// Frames prove the credential was accepted: the next `4401` is a
			// fresh expiry and may refresh again.
			this.refreshedSinceOpen = false;
			for (const pending of [...entry.pending]) {
				pending.resolve();
			}
			for (const handler of entry.handlers) {
				handler(frame);
			}
		}
	}

	private entryReceives(entry: PathEntry, channel: string): boolean {
		if (entry.receiveAll) {
			return true;
		}
		return entry.baseChannel !== null && channelMatches(entry.baseChannel, channel);
	}

	private rejectPath(path: string, error: ApiError | UsageError): void {
		const entry = this.paths.get(path);
		if (entry === undefined) {
			return;
		}
		// The server did not register the path, so the subscription is dead:
		// drop it. A pending promise rejects; `subscribe()` may run again.
		this.dropPath(entry, error);
		this.emitRefusal(error);
	}

	/** Rejects every pending promise of one path and drops it. No refusal
	 *  emit — the caller decides whether the drop is a refusal event. */
	private dropPath(entry: PathEntry, error: ApiError | UsageError): void {
		this.paths.delete(entry.path);
		for (const pending of [...entry.pending]) {
			pending.reject(error);
		}
	}

	/** Delivers one refusal event to the handlers. One emit per event, however
	 *  many paths and pending promises the refusal covers. */
	private emitRefusal(error: ApiError | UsageError): void {
		for (const listener of [...this.refusalListeners]) {
			listener(error);
		}
	}

	private handleClose(code: number): void {
		this.socket = null;
		this.state = 'idle';
		const settle = this.dialSettle;
		this.dialSettle = null;
		this.opening = null;
		if (this.closedByCaller) {
			settle?.reject(new NetworkError('The socket closed before it opened.'));
			return;
		}
		// Classify the close before the dial rejects: a refusal (4401/4403)
		// must reach the opener as the actionable error, not as a network drop.
		const refused = this.terminalCloseError(code);
		settle?.reject(refused ?? new NetworkError('The socket closed before it opened.'));
		if (refused !== null) {
			this.fail(refused);
			return;
		}
		if (code === 4401) {
			this.handleAuthClose();
			return;
		}
		this.scheduleReconnect();
	}

	/** The terminal refusal a close code carries, or `null` when the close is
	 *  recoverable — a network drop, or a first `4401` a refreshable provider
	 *  can recover from. */
	private terminalCloseError(code: number): ApiError | UsageError | null {
		if (code === 4403) {
			return new AuthError(
				'The server closed the socket with 4403: the origin is not allowlisted for this app. Register the origin on the app and connect again.'
			);
		}
		if (code === 4401 && (this.auth?.refreshOn401 === undefined || this.refreshedSinceOpen)) {
			return new AuthError(
				'The server refused the socket credential (close 4401). A browser provider refreshes the access token once; static fct_ keys need a header-capable transport — inject one with realtime({ WebSocket }).'
			);
		}
		return null;
	}

	/** `4401` with a refreshable provider on its first refusal: refresh once
	 *  and reconnect. The dial already rejected; subscriptions stay pending
	 *  for the resend on the new socket. */
	private handleAuthClose(): void {
		const refresh = this.auth?.refreshOn401;
		if (refresh === undefined || this.refreshedSinceOpen) {
			return;
		}
		this.refreshedSinceOpen = true;
		this.opening = refresh()
			.then(() => {
				// End the failed dial cycle before the new one starts, so
				// `open()` dials instead of joining this very chain.
				this.opening = null;
				return this.open();
			})
			.catch((error: unknown) => {
				this.opening = null;
				this.fail(error instanceof ApiError ? error : new AuthError(errorMessage(error)));
			});
	}

	private fail(error: ApiError | UsageError): void {
		this.terminalError = error;
		for (const entry of [...this.paths.values()]) {
			this.dropPath(entry, error);
		}
		// One signal for the terminal refusal, however many subscriptions it
		// took down.
		this.emitRefusal(error);
	}

	private scheduleReconnect(): void {
		if (this.timer !== null || this.closedByCaller || this.terminalError !== null) {
			return;
		}
		this.timer = setTimeout(() => {
			this.timer = null;
			this.delay = Math.min(this.delay * RECONNECT_FACTOR, RECONNECT_MAX_MS);
			void this.open().catch((error: unknown) => {
				this.opening = null;
				if (error instanceof AuthError || error instanceof UsageError) {
					this.fail(error);
					return;
				}
				this.scheduleReconnect();
			});
		}, this.delay);
	}

	private unsubscribe(path: string, handler: FrameHandler): void {
		const entry = this.paths.get(path);
		if (entry === undefined) {
			return;
		}
		entry.handlers.delete(handler);
		if (entry.handlers.size > 0) {
			return;
		}
		this.paths.delete(path);
		this.sendFrame({ action: 'unsubscribe', args: [path] });
	}

	private sendFrame(frame: unknown): void {
		const socket = this.socket;
		if (socket === null || this.state !== 'open') {
			return;
		}
		try {
			socket.send(JSON.stringify(frame));
		} catch {
			// The close event follows and drives the reconnect.
		}
	}
}
