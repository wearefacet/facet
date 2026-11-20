// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Builder-mode WebSocket wiring.
 *
 * Connects the shared socket and subscribes the channels the draft-model
 * hot reload depends on: the per-draft document channel and the
 * `/core/DocType` collection channel. Also wires the dead-drop recovery —
 * a refresh on every re-open, and an immediate reconnect when the tab
 * becomes visible again.
 *
 * Two hosts use it: the `/Builder` editor routes (draft sidebar refresh)
 * and live routes during an active preview session (the draft's nav + open
 * page refresh while the assistant or a second tab mutates the draft). The
 * socket is cookie-authenticated in both cases — the caller's real
 * principal — so no preview-carve-out exists on the wire; the preview
 * scoping happens in the REST rebuilds the handlers run.
 *
 * The module owns the subscription plumbing only. What happens on an event
 * (invalidateAll + nav rebuild) is the caller's `onModelChange` — that part
 * needs SvelteKit and stays in the root layout. Returns a cleanup function
 * so a single `$effect` in the layout can own the lifecycle.
 */

import {
	getWebSocketClient,
	subscribeToDocument,
	onWebSocketReconnect,
	ensureWebSocketConnected
} from '$lib/websocket.svelte.js';

/** Input for {@link subscribeBuilderModel}. */
export interface SubscribeBuilderModelInput {
	/** The active draft-domain route param (`[draftDomain]`). Empty on the
	 *  Builder landing page — the per-draft subscription is then skipped. */
	draftDomain: string;
	/** Runs on every per-draft or collection event and after every
	 *  re-open. The caller refreshes the nav model here. */
	onModelChange: () => void;
}

/**
 * Connects the socket, subscribes the builder channels, and installs the
 * reconnect + visibility recovery. Returns a cleanup function that removes
 * every subscription and listener.
 *
 * Call from an effect keyed on the builder route and the draft param — the
 * effect re-runs (and resubscribes) when either changes, exactly as the
 * inline effect did before the extraction.
 */
export function subscribeBuilderModel(input: SubscribeBuilderModelInput): () => void {
	const unsubs: Array<() => void> = [];

	getWebSocketClient().connect();

	const handler = input.onModelChange;

	// The per-draft subscription needs the route param. The collection
	// subscription covers every /Builder page, including the landing page
	// where drafts are created from existing domains — the copy fires a
	// `registered` event per doctype, and a channel left unsubscribed
	// there would miss them (no replay after a missed delivery). Never
	// replace it with a per-doctype loop: doctypes created after this
	// call ran would have no listener.
	if (input.draftDomain) {
		unsubs.push(subscribeToDocument(`/core/Domain/${input.draftDomain}`, handler));
	}
	unsubs.push(subscribeToDocument('/core/DocType', handler));

	// Dead-drop recovery. The socket delivers no replay while disconnected
	// (doc/backend/websocket.md → Known Limitations), so re-fetch on every
	// re-open. Tab sleep can sit out the close event; returning forces one
	// immediate reconnect attempt when the client knows the socket is down.
	unsubs.push(onWebSocketReconnect(handler));
	const onVisible = () => {
		if (document.visibilityState === 'visible') ensureWebSocketConnected();
	};
	document.addEventListener('visibilitychange', onVisible);
	unsubs.push(() => document.removeEventListener('visibilitychange', onVisible));

	return () => {
		for (const unsub of unsubs) unsub();
	};
}
