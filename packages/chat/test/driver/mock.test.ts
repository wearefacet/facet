// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it } from 'vitest';
import { createMockAssistant } from '../../src/index.js';
import type { AssistantSseEvent } from '../../src/index.js';

/**
 * Smoke tests for the ported mock — the full scripted machinery is
 * exercised by the chat component stories in the main app. These pin the
 * package export and the two stream exit paths the driver contract names.
 */

async function collect(iterable: AsyncIterable<AssistantSseEvent>): Promise<AssistantSseEvent[]> {
	const out: AssistantSseEvent[] = [];
	for await (const ev of iterable) out.push(ev);
	return out;
}

describe('createMockAssistant', () => {
	it('streams a scripted workspace turn and persists the turn row', async () => {
		const driver = createMockAssistant();
		const conv = await driver.createWorkspaceConversation();
		const events = await collect(driver.streamAsk(conv.id, { content: 'list customers' }));

		expect(events[0]).toMatchObject({ event: 'meta' });
		expect(events.at(-1)).toMatchObject({ event: 'done' });

		const turns = await driver.listTurns(conv.id);
		expect(turns).toHaveLength(1);
		expect(turns[0]?.status).toBe('done');

		const latest = await driver.latestTurn(conv.id);
		expect(latest?.status).toBe('done');
	});

	it('emits cancelled when cancel lands mid-stream', async () => {
		const driver = createMockAssistant();
		const conv = await driver.createWorkspaceConversation();
		const stream = driver.streamAsk(conv.id, { content: 'cancel please' });

		const events: AssistantSseEvent[] = [];
		for await (const ev of stream) {
			events.push(ev);
			if (ev.event === 'meta') await driver.cancel(ev.turn_token);
		}
		expect(events.at(-1)).toEqual({ event: 'cancelled' });

		const latest = await driver.latestTurn(conv.id);
		expect(latest?.status).toBe('cancelled');
	});

	it('scopes the list with the app filter wire form', async () => {
		const driver = createMockAssistant();
		await driver.createConversation({ context: { kind: 'app', app_id: 'app_1' } });
		await driver.createWorkspaceConversation();

		const result = await driver.listConversations({
			filters: { 'context.kind__eq': 'app', 'context.app_id__eq': 'app_1' }
		});
		expect(result.data).toHaveLength(1);
		expect(result.data[0]?.context).toMatchObject({ kind: 'app', app_id: 'app_1' });
	});
});
