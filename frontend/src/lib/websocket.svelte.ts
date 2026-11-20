// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * WebSocket client for the Facet real-time bridge.
 *
 * Manages a single `/Ws` connection per browser tab. Components subscribe to
 * individual document paths (e.g. `"/core/Domain/_abc123"`) and receive
 * events when those documents are created, updated, or deleted.
 *
 * The wire protocol matches `src/websocket/connection.cr`:
 *
 * - **Incoming (client → server):**
 *   ```json
 *   {"action": "subscribe",   "args": ["/hr/Employee/e1"]}
 *   {"action": "unsubscribe", "args": ["/hr/Employee/e1"]}
 *   ```
 * - **Outgoing (server → client):**
 *   ```json
 *   {
 *     "channel": "fanout:hr.Employee:hr.Employee.e1",
 *     "event":   "updated",
 *     "payload": {"id": "hr.Employee.e1"},
 *     "headers": {"mutation_id": "01J...", "actioner_id": "user_1", "domain": "hr", "doc_type": "Employee"}
 *   }
 *   ```
 *
 * Auth is cookie-based (HttpOnly cookies sent on the WS upgrade) — same as
 * the IAM session, so no token management is needed here.
 */

import { untrack } from 'svelte';
import { SvelteSet } from 'svelte/reactivity';
import { apiFetch, redirectToLogin } from './session.svelte.js';

export interface WsDocumentEvent {
	/** The fanout channel, e.g. `fanout:core.DocType:core.DocType._abc.Invoice`. */
	channel: string;
	/** Event type: `created`, `updated`, `deleted`. */
	event: string;
	/** The document payload (at minimum `{ id }`). */
	payload: Record<string, unknown>;
	/** Headers carrying mutation metadata. */
	headers: {
		mutation_id?: string;
		actioner_id?: string;
		domain?: string;
		doc_type?: string;
	};
}

type EventListener = (event: WsDocumentEvent) => void;

/** Callback run after the socket re-opens following a drop. */
type ReconnectListener = () => void;

/** Close code the server sends when the handshake auth fails. */
const AUTH_FAILED_CLOSE_CODE = 4401;

/**
 * Probes the cookie session after a socket close.
 *
 * The browser does not expose the HTTP status of a refused WebSocket
 * handshake: a 401 and a network drop both surface as close code 1006. One
 * authenticated request tells them apart. The probe goes through `apiFetch`
 * with `attemptRefresh`, so an expired access token is renewed from a still-
 * valid refresh token before the decision: only a failed refresh (or a
 * genuinely dead session) yields 401. `redirectOnFailure: false` keeps the
 * redirect in this client's hands. A network error counts as transient.
 */
async function sessionIsLive(): Promise<boolean> {
	try {
		const res = await apiFetch('/Api/iam/me', undefined, {
			attemptRefresh: true,
			redirectOnFailure: false
		});
		return res.status !== 401;
	} catch {
		return true;
	}
}

/**
 * Reconnecting WebSocket client. Subscriptions are tracked so they can be
 * re-sent after a reconnect. Events are dispatched to listeners filtered by
 * the document path they subscribed to.
 */
class WebSocketClient {
	private socket: WebSocket | null = null;
	private url: string;
	/** Paths subscribed via `subscribe()`, keyed by path for de-dup. */
	// untrack on all reads/writes below: this is event bookkeeping, never
	// render state, and the client's methods run inside component effects —
	// a tracked read + the listener-set write would re-run that effect.
	private subscriptions = untrack(() => new Map<string, Set<EventListener>>());
	/** Whether `connect()` has been called — guards against double-connect on HMR. */
	private started = false;
	private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
	private reconnectDelay = 1000;
	/** Callbacks run after the socket re-opens following a drop. */
	private reconnectListeners = new Set<ReconnectListener>();
	/** True once the socket has opened. Reconnect callbacks fire from the
	 *  second open on — before the first open, no delivery was missed. */
	private everConnected = false;
	/** True once the session is known dead. Blocks every reconnect path —
	 *  the socket, the backoff timer, and `ensureConnected` — until the page
	 *  reloads after the `/Login` redirect. */
	private sessionExpired = false;

	constructor(url: string) {
		this.url = url;
	}

	/**
	 * Opens the WebSocket connection. Safe to call multiple times — only the
	 * first call actually connects; subsequent calls are no-ops.
	 */
	connect(): void {
		if (this.started || this.sessionExpired) return;
		this.started = true;
		this.open();
	}

	private open(): void {
		if (this.sessionExpired) return;
		if (typeof window === 'undefined') return;

		const proto = window.location.protocol === 'https:' ? 'wss:' : 'ws:';
		const fullUrl = this.url || `${proto}//${window.location.host}/Ws`;

		try {
			this.socket = new WebSocket(fullUrl);
		} catch {
			this.scheduleReconnect();
			return;
		}

		this.socket.onopen = () => {
			this.reconnectDelay = 1000;
			// Re-send all active subscriptions after (re)connect.
			const paths = untrack(() => Array.from(this.subscriptions.keys()));
			if (paths.length > 0) {
				this.send({ action: 'subscribe', args: paths });
			}
			// The server delivers no replay while disconnected, so listeners
			// re-fetch the updates they missed. Skip the first open — nothing
			// was missed before it.
			if (this.everConnected) {
				for (const cb of this.reconnectListeners) cb();
			}
			this.everConnected = true;
		};

		this.socket.onmessage = (e: MessageEvent) => {
			this.handleMessage(e.data);
		};

		this.socket.onclose = (event: CloseEvent) => {
			this.socket = null;
			this.handleClose(event.code);
		};

		this.socket.onerror = () => {
			// The close handler will fire next and trigger reconnect.
		};
	}

	/**
	 * Routes a close event: an auth close stops at once; any other close keeps
	 * the existing backoff and probes the session in parallel, so a 401
	 * handshake stops the loop instead of reconnecting forever.
	 */
	private handleClose(code: number): void {
		if (this.sessionExpired) return;
		if (code === AUTH_FAILED_CLOSE_CODE) {
			this.expireSession();
			return;
		}
		this.scheduleReconnect();
		void this.expireIfSessionDead();
	}

	/**
	 * Probes the session after a non-auth close. A 401 stops the loop and
	 * redirects to `/Login`; a live session (or a network error) leaves the
	 * backoff timer running.
	 */
	private async expireIfSessionDead(): Promise<void> {
		const live = await sessionIsLive();
		// `disconnect()` may have run while the probe was in flight.
		if (!this.started || this.sessionExpired) return;
		if (!live) this.expireSession();
	}

	/** Stops every reconnect path and sends the user to `/Login`. */
	private expireSession(): void {
		if (this.sessionExpired) return;
		this.sessionExpired = true;
		if (this.reconnectTimer) {
			clearTimeout(this.reconnectTimer);
			this.reconnectTimer = null;
		}
		if (this.socket) {
			this.socket.onclose = null;
			this.socket.close();
			this.socket = null;
		}
		redirectToLogin();
	}

	private scheduleReconnect(): void {
		if (this.sessionExpired || this.reconnectTimer || this.socket) return;
		this.reconnectTimer = setTimeout(() => {
			this.reconnectTimer = null;
			this.reconnectDelay = Math.min(this.reconnectDelay * 1.5, 10000);
			this.open();
		}, this.reconnectDelay);
	}

	private send(frame: unknown): void {
		if (this.socket && this.socket.readyState === WebSocket.OPEN) {
			this.socket.send(JSON.stringify(frame));
		}
	}

	private handleMessage(data: unknown): void {
		let msg: Record<string, unknown>;
		try {
			msg = JSON.parse(data as string);
		} catch {
			return;
		}

		// Server error frames have `{ "error": "..." }` — skip silently.
		if (msg['error']) return;

		const wsEvent = msg as unknown as WsDocumentEvent;
		if (!wsEvent.channel || !wsEvent.event) return;

		// Dispatch to all listeners whose subscribed path matches the channel.
		untrack(() => {
			for (const [, listeners] of this.subscriptions) {
				// The fanout channel format is `fanout:{domain}.{doc_type}:{doc_id}`.
				// We can't perfectly reverse-map a channel to a path, so we notify
				// all listeners and let them filter. This is fine for the low-volume
				// builder-mode use case.
				for (const listener of listeners) {
					listener(wsEvent);
				}
			}
		});
	}

	/**
	 * Subscribes to a document path and registers a listener for events on it.
	 * Returns an unsubscribe function that removes the listener and sends
	 * `unsubscribe` when the last listener for a path is removed.
	 *
	 * @param path Resource path, e.g. `"/core/Domain/_abc123"` or `"/core/DocType/core.DocType._abc.Invoice"`
	 * @param listener Called whenever a WS event arrives (for any subscribed path)
	 */
	subscribe(path: string, listener: EventListener): () => void {
		return untrack(() => {
			let listeners = this.subscriptions.get(path);
			if (!listeners) {
				listeners = new SvelteSet();
				this.subscriptions.set(path, listeners);
			}
			listeners.add(listener);

			// Send the subscribe frame if the socket is open.
			this.send({ action: 'subscribe', args: [path] });

			return () => {
				const set = this.subscriptions.get(path);
				if (!set) return;
				set.delete(listener);
				if (set.size === 0) {
					this.subscriptions.delete(path);
					this.send({ action: 'unsubscribe', args: [path] });
				}
			};
		});
	}

	/**
	 * True when the socket is currently open. Reflects the client's own
	 * knowledge: a silently-dead connection still reports `true` until the
	 * close event lands.
	 */
	isConnected(): boolean {
		return this.socket?.readyState === WebSocket.OPEN;
	}

	/**
	 * Reconnects at once when the socket is down. No-op when the socket is
	 * open, connecting, or closing. Used when the tab becomes visible again
	 * after sleep: delivery missed while hidden cannot be replayed, so the
	 * first retry should not wait on the reconnect backoff timer.
	 */
	ensureConnected(): void {
		if (this.sessionExpired || this.socket) return;
		if (this.reconnectTimer) {
			clearTimeout(this.reconnectTimer);
			this.reconnectTimer = null;
		}
		this.open();
	}

	/**
	 * Registers a callback run after every successful re-open that follows a
	 * drop. Returns an unsubscribe function.
	 */
	onReconnect(listener: ReconnectListener): () => void {
		this.reconnectListeners.add(listener);
		return () => this.reconnectListeners.delete(listener);
	}

	/** Closes the connection and clears all subscriptions. */
	disconnect(): void {
		untrack(() => this.subscriptions.clear());
		if (this.reconnectTimer) {
			clearTimeout(this.reconnectTimer);
			this.reconnectTimer = null;
		}
		if (this.socket) {
			this.socket.onclose = null; // prevent reconnect
			this.socket.close();
			this.socket = null;
		}
		this.started = false;
		this.everConnected = false;
		this.sessionExpired = false;
	}
}

let client: WebSocketClient | null = null;

/**
 * Returns the singleton WebSocket client. The first call creates and connects
 * the socket; subsequent calls return the same instance.
 */
export function getWebSocketClient(): WebSocketClient {
	if (!client) {
		client = new WebSocketClient('/Ws');
	}
	return client;
}

/**
 * Convenience: subscribes to a single document and returns an unsubscribe
 * function. Paths follow the `{domain}/{Doctype}/{id}` format.
 */
export function subscribeToDocument(path: string, listener: EventListener): () => void {
	return getWebSocketClient().subscribe(path, listener);
}

/**
 * Convenience: returns an unsubscribe function that removes a reconnect
 * listener registered on the singleton client.
 */
export function onWebSocketReconnect(listener: ReconnectListener): () => void {
	return getWebSocketClient().onReconnect(listener);
}

/**
 * Convenience: forces an immediate reconnect on the singleton client when
 * the socket is down. No-op when it is open or already connecting.
 */
export function ensureWebSocketConnected(): void {
	getWebSocketClient().ensureConnected();
}
