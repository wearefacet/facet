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
 * Live list refresh — the collection WebSocket channel for a host that
 * shows one doctype's listing (the `/{domain}/{doctype}` list route).
 *
 * The server publishes every default-path event of a doctype to the
 * collection channel (`fanout:{domain}.{doc_type}`) beside the per-document
 * channel. On any frame for that doctype the host's `refresh()` runs:
 * trailing-debounced, so a burst of frames (a multi-row mutation, or the
 * duplicate copy a per-document subscription in the same tab receives)
 * coalesces into one re-query. The refresh re-runs the listing's current
 * query — view, filters, and paging stay as they are.
 *
 * Frames are hints, not source of truth. Delivery is at-most-once with no
 * replay (doc/backend/websocket.md → Known Limitations), so a missed event
 * shows as staleness until the next event, the reconnect refresh, or a
 * manual reload. The re-query goes through REST, which re-checks RBAC — a
 * lost grant surfaces as the list error, never as stale-authorized rows.
 *
 * Silent degradation: a rejected subscribe (the per-doctype subscriber cap,
 * a lost read grant, an unsupported path) answers an error frame the shared
 * client already skips (`websocket.svelte.ts` → `handleMessage`). The
 * listener stays registered, no events arrive, and the listing keeps
 * working on its manual refresh — no retry, no toast, no log.
 */

/** Trailing debounce for collection-event refetches, in milliseconds. */
export const REFRESH_DEBOUNCE_MS = 300;

/**
 * Whether one WebSocket frame is a mutation of the subscribed collection.
 *
 * The frame contract: the publish headers carry `domain` and `doc_type` of
 * the mutated document, so a frame whose headers name the collection is a
 * mutation of one of its rows — whatever the event name (`created`,
 * `updated`, `deleted`, and every named action). `child_changed` is the one
 * exception: its headers name the parent doctype, but the frame describes a
 * child mutation — no listed row changed, so no list refresh.
 */
export function isCollectionEvent(
	event: WsDocumentEvent,
	domain: string,
	docType: string
): boolean {
	if (event.event === 'child_changed') return false;
	return event.headers['domain'] === domain && event.headers['doc_type'] === docType;
}

export interface SubscribeCollectionRefreshInput {
	/** Collection domain (path segment, e.g. `crm`). */
	domain: string;
	/** Collection doctype (path segment, e.g. `Company`). */
	docType: string;
	/** Re-runs the host's listing query with its current state. */
	refresh: () => void;
}

/**
 * Connects the shared socket, subscribes the collection channel, and
 * installs the reconnect + visibility recovery. Returns a cleanup function
 * that drops a pending refetch and removes every subscription and listener.
 *
 * Call from an effect keyed on the collection identity — the effect re-runs
 * (and resubscribes) when the host navigates to another listing.
 */
export function subscribeCollectionRefresh(input: SubscribeCollectionRefreshInput): () => void {
	const unsubs: Array<() => void> = [];

	getWebSocketClient().connect();

	let timer: ReturnType<typeof setTimeout> | null = null;
	const scheduleRefresh = (): void => {
		if (timer) clearTimeout(timer);
		timer = setTimeout(() => {
			timer = null;
			input.refresh();
		}, REFRESH_DEBOUNCE_MS);
	};

	// `handleMessage` dispatches every frame to every listener — the client
	// cannot reverse-map a fanout channel to a path — so the filter is ours:
	// the frame contract in `isCollectionEvent`.
	const handler = (event: WsDocumentEvent): void => {
		if (!isCollectionEvent(event, input.domain, input.docType)) return;
		scheduleRefresh();
	};

	unsubs.push(subscribeToDocument(`/${input.domain}/${input.docType}`, handler));

	// No replay while disconnected — re-fetch whatever the drop missed (the
	// client contract: on reconnect the client MUST re-fetch). The debounce
	// folds this into an event burst that lands around the re-open.
	unsubs.push(onWebSocketReconnect(scheduleRefresh));

	// Tab sleep can sit out the close event; returning forces one immediate
	// reconnect attempt instead of waiting on the backoff timer.
	const onVisible = (): void => {
		if (document.visibilityState === 'visible') ensureWebSocketConnected();
	};
	document.addEventListener('visibilitychange', onVisible);
	unsubs.push(() => document.removeEventListener('visibilitychange', onVisible));

	return () => {
		if (timer) {
			clearTimeout(timer);
			timer = null;
		}
		for (const unsub of unsubs) unsub();
	};
}
