// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it } from 'vitest';
import { runCatchup } from '../../src/driver/catchup.js';
import type { TurnSummary } from '../../src/driver/types.js';

/**
 * Builds a sleep stub that just resolves — no real time passes, the loop is
 * driven purely by the queued summaries below.
 */
const instantSleep = () => Promise.resolve();

function summary(status: TurnSummary['status']): TurnSummary {
	return {
		id: '01SUMMARY0000000000000000',
		idx: 1,
		status,
		finish_reason: status === 'done' ? 'stop' : null,
		error: status === 'error' ? 'boom' : status === 'cancelled' ? 'cancelled' : null,
		request_messages: [],
		response_messages: [],
		created_at: '2026-09-24T00:00:00Z'
	};
}

describe('runCatchup', () => {
	it('resolves settled immediately when the turn already ended', async () => {
		const outcome = await runCatchup(() => Promise.resolve(summary('done')), instantSleep, {
			intervalMs: 1,
			timeoutMs: 10
		});
		expect(outcome).toEqual({ outcome: 'settled', summary: summary('done') });
	});

	it('waits through running polls until the turn settles', async () => {
		const queue = [summary('running'), summary('running'), summary('done')];
		let sleepCount = 0;
		const outcome = await runCatchup(
			() => Promise.resolve(queue.shift() ?? summary('done')),
			() => {
				sleepCount += 1;
				return Promise.resolve();
			},
			{ intervalMs: 1, timeoutMs: 10_000 }
		);
		expect(sleepCount).toBe(2);
		expect(outcome).toEqual({ outcome: 'settled', summary: summary('done') });
	});

	it('calls onTick with each running summary and never with the terminal one', async () => {
		// Two running polls whose partial exchange grows, then the settle —
		// the caller renders the growing partial through onTick while the
		// backend generates.
		const firstRunning = summary('running');
		const secondRunning: TurnSummary = {
			...summary('running'),
			response_messages: [{ role: 'assistant', content: 'partial' }]
		};
		const done = summary('done');
		const queue = [firstRunning, secondRunning, done];
		const ticks: TurnSummary[] = [];
		const outcome = await runCatchup(() => Promise.resolve(queue.shift() ?? done), instantSleep, {
			intervalMs: 1,
			timeoutMs: 10_000,
			onTick: (s) => {
				ticks.push(s);
			}
		});
		expect(ticks).toEqual([firstRunning, secondRunning]);
		expect(outcome).toEqual({ outcome: 'settled', summary: done });
	});

	it('resolves settled on an error turn with its message', async () => {
		const outcome = await runCatchup(() => Promise.resolve(summary('error')), instantSleep, {
			intervalMs: 1,
			timeoutMs: 10
		});
		expect(outcome.outcome === 'settled' && outcome.summary.error === 'boom').toBe(true);
	});

	it('resolves settled on a cancelled turn', async () => {
		const outcome = await runCatchup(() => Promise.resolve(summary('cancelled')), instantSleep, {
			intervalMs: 1,
			timeoutMs: 10
		});
		expect(outcome.outcome === 'settled' && outcome.summary.status === 'cancelled').toBe(true);
	});

	it('reports timeout when the budget expires while still running', async () => {
		const outcome = await runCatchup(
			() => Promise.resolve(summary('running')),
			() => {
				// Advance the clock without real waiting: each "sleep" is a
				// microtask, so the wall-clock budget must cover many polls.
				return Promise.resolve();
			},
			{ intervalMs: 1, timeoutMs: 0 }
		);
		// deadline = now + 0 → the FIRST terminal check falls through to the
		// deadline check after the first running poll.
		expect(outcome).toEqual({ outcome: 'timeout' });
	});

	it('reports no_turn when the conversation has no turns at all', async () => {
		const outcome = await runCatchup(() => Promise.resolve(null), instantSleep, {
			intervalMs: 1,
			timeoutMs: 10
		});
		expect(outcome).toEqual({ outcome: 'no_turn' });
	});
});
