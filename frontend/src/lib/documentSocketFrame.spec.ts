// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { isDocumentMutation } from './documentSocket.svelte.js';
import type { WsDocumentEvent } from './websocket.svelte.js';

/**
 * Unit tests for the live-refresh frame contract (`isDocumentMutation`).
 *
 * A frame whose `payload.id` names the subscribed document is a mutation of
 * it — whatever the event name. Named actions publish past-tense event
 * names of their own (e.g. `closed`), and the client must not copy the
 * backend's inflector into TypeScript, so the check is identity-based with
 * one exception: `child_changed` frames are keyed to the parent, and the
 * payload id names the parent, never a mutation of this document's content.
 */

function frame(event: string, id: string): WsDocumentEvent {
	return { channel: `fanout:hr.Employee:${id}`, event, payload: { id }, headers: {} };
}

describe('isDocumentMutation — the live-refresh frame contract', () => {
	const docId = 'hr.Employee.e1';

	it('refreshes on the standard mutation events', () => {
		expect(isDocumentMutation(frame('created', docId), docId)).toBe(true);
		expect(isDocumentMutation(frame('updated', docId), docId)).toBe(true);
		expect(isDocumentMutation(frame('deleted', docId), docId)).toBe(true);
	});

	it('refreshes on an action-named event', () => {
		expect(isDocumentMutation(frame('closed', docId), docId)).toBe(true);
		expect(isDocumentMutation(frame('archived', docId), docId)).toBe(true);
	});

	it('does not refresh on a child_changed envelope frame', () => {
		// The child_changed frame is keyed to the parent; its payload.id names
		// the parent of an owned-child mutation, not this document's content.
		expect(isDocumentMutation(frame('child_changed', docId), docId)).toBe(false);
	});

	it('does not refresh on a foreign document id', () => {
		expect(isDocumentMutation(frame('updated', 'hr.Employee.other'), docId)).toBe(false);
		expect(isDocumentMutation(frame('closed', 'hr.Employee.other'), docId)).toBe(false);
		expect(isDocumentMutation(frame('child_changed', 'hr.Employee.other'), docId)).toBe(false);
	});

	it('does not refresh when the frame carries no id', () => {
		const bare: WsDocumentEvent = {
			channel: 'fanout:hr.Employee',
			event: 'updated',
			payload: {},
			headers: {}
		};
		expect(isDocumentMutation(bare, docId)).toBe(false);
	});
});
