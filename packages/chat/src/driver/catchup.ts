// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { TurnSummary } from './types.js';

/**
 * Catch-up poll for a broken assistant stream.
 *
 * When `streamAsk` ends abnormally (network blip, page refresh on the
 * server side, provider hiccup after the sink died), the backend may still
 * be running the turn — the row sits at `status: 'running'`. This poll
 * reads `GET /:id/turns/latest` on a fixed cadence until the conversation's
 * latest turn reaches a terminal status (`done` / `error` / `cancelled`),
 * then resolves. The caller refetches `listTurns` and rebuilds the thread
 * from server truth.
 *
 * The one-running-turn invariant (backend 409 guard) makes "latest" cheap:
 * at most one turn can ever be `running` on the conversation, so the
 * terminal transition of the latest row is exactly the end of the orphaned
 * generation.
 */

/** Tuning knobs — injected so tests can shrink the cadence. */
export interface CatchupOptions {
	/** Cadence between polls. */
	intervalMs: number;
	/** Total budget before the poll gives up. */
	timeoutMs: number;
	/** Called after each poll that found the turn still running. Lets the
	 * caller render the running row's partial exchange while it generates. */
	onTick?: (summary: TurnSummary) => void;
}

export const DEFAULT_CATCHUP_OPTIONS: CatchupOptions = {
	intervalMs: 3000,
	timeoutMs: 180_000
};

/** Sleep primitive — injectable for fake-timer tests. */
export type Sleep = (ms: number) => Promise<void>;

/** The conversation's current turn state as observed through the driver. */
export type LatestTurnProvider = () => Promise<TurnSummary | null>;

/**
 * Outcome of the poll.
 *
 * - `settled` — the latest turn reached a terminal status. `summary`
 *   holds it; the caller rebuilds the thread from `listTurns`.
 * - `timeout` — the budget ran out while the turn was still `running`.
 *   The caller keeps the partial text and the error note; the turn row
 *   will surface on the next reload (or the sweep marks it `interrupted`).
 * - `no_turn` — the conversation reported no turns at all; the backend
 *   never opened the row (very early disconnect). The caller keeps its
 *   local error state.
 */
export type CatchupOutcome =
	{ outcome: 'settled'; summary: TurnSummary } | { outcome: 'timeout' } | { outcome: 'no_turn' };

/**
 * Polls `latestTurn` until the latest turn is terminal.
 *
 * Resolution is checked IMMEDIATELY (before the first sleep), so a turn
 * that completed between the stream break and the catch-up start resolves
 * without waiting one interval.
 */
export async function runCatchup(
	latestTurn: LatestTurnProvider,
	sleep: Sleep,
	options: CatchupOptions = DEFAULT_CATCHUP_OPTIONS
): Promise<CatchupOutcome> {
	const deadline = Date.now() + options.timeoutMs;

	while (true) {
		const summary = await latestTurn();

		if (!summary) {
			return { outcome: 'no_turn' };
		}
		if (summary.status !== 'running') {
			return { outcome: 'settled', summary };
		}
		// Still running — hand the summary over so the caller can render the
		// row's checkpointed partial exchange while the backend generates.
		options.onTick?.(summary);
		if (Date.now() >= deadline) {
			return { outcome: 'timeout' };
		}

		await sleep(options.intervalMs);
	}
}
