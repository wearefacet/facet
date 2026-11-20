// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import {
	getWebSocketClient,
	subscribeToDocument,
	onWebSocketReconnect,
	ensureWebSocketConnected,
	type WsDocumentEvent
} from './websocket.svelte.js';

/**
 * Live document refresh — the per-document WebSocket channel for a host
 * that shows one document (the `/{domain}/{doctype}/{id}` show route).
 *
 * On any frame whose `payload.id` names the shown document — `created` /
 * `updated` / `deleted` and every action event (e.g. `closed`) — the host's
 * `refresh()` runs: it drops the cached projection and re-runs the route
 * load. This is the event-driven half of the show-cache contract; the
 * datasource ref's own mutation paths (`ref.invalidate()` after
 * out-of-band endpoints) stay the guarantee for the caller's own actions,
 * because channel delivery is at-most-once with no replay
 * (doc/backend/websocket.md → Known Limitations).
 *
 * Frames are hints, not source of truth: `refresh()` re-reads through REST,
 * which re-checks RBAC — a lost grant surfaces as the load error, never as
 * stale-authorized content.
 */

/** SvelteKit load-dependency key for one document's show data. The route
 *  load declares it with `depends()`; the live handler invalidates it. The
 *  return type mirrors SvelteKit's `${string}:${string}` dependency shape. */
export function documentDependencyKey(docId: string): `${string}:${string}` {
	return `facet:doc:${docId}`;
}

/**
 * Whether one WebSocket frame is a mutation of the subscribed document.
 *
 * The frame contract: a frame whose `payload.id` names the document is a
 * mutation of it — whatever the event name (`created`, `updated`,
 * `deleted`, and every action event such as `closed`). `child_changed` is
 * the one exception: its `payload.id` names the parent of an owned-child
 * mutation, so the frame never describes this document's own content.
 */
export function isDocumentMutation(event: WsDocumentEvent, docId: string): boolean {
	if (event.payload['id'] !== docId) return false;
	if (event.event === 'child_changed') return false;
	return true;
}

export interface SubscribeDocumentRefreshInput {
	/** Document domain (path segment, e.g. `iam`). */
	domain: string;
	/** Document doctype (path segment, e.g. `Account`). */
	docType: string;
	/** The document's projection id (`doc.meta.id`, e.g. `iam.Account.ada`). */
	docId: string;
	/** Drops the cached document read and re-runs the host's loads. */
	refresh: () => void;
}

/**
 * Connects the shared socket, subscribes the document's channel, and
 * installs the reconnect + visibility recovery. Returns a cleanup function
 * that removes every subscription and listener.
 *
 * Call from an effect keyed on the document identity — the effect re-runs
 * (and resubscribes) when the host navigates to another document.
 */
export function subscribeDocumentRefresh(input: SubscribeDocumentRefreshInput): () => void {
	const unsubs: Array<() => void> = [];

	getWebSocketClient().connect();

	// `handleMessage` dispatches every frame to every listener — the client
	// cannot reverse-map a fanout channel to a path — so the filter is ours:
	// the frame contract in `isDocumentMutation`. An allow-list of event
	// names would go stale on every new named action; the payload id carries
	// the identity.
	const handler = (event: WsDocumentEvent): void => {
		if (!isDocumentMutation(event, input.docId)) return;
		input.refresh();
	};

	unsubs.push(subscribeToDocument(`/${input.domain}/${input.docType}/${input.docId}`, handler));

	// No replay while disconnected — re-fetch whatever the drop missed (the
	// client contract: on reconnect the client MUST re-fetch).
	unsubs.push(onWebSocketReconnect(input.refresh));

	// Tab sleep can sit out the close event; returning forces one immediate
	// reconnect attempt instead of waiting on the backoff timer.
	const onVisible = (): void => {
		if (document.visibilityState === 'visible') ensureWebSocketConnected();
	};
	document.addEventListener('visibilitychange', onVisible);
	unsubs.push(() => document.removeEventListener('visibilitychange', onVisible));

	return () => {
		for (const unsub of unsubs) unsub();
	};
}
