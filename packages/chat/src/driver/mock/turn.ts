// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type { Turn, TurnSummary } from '../types.js';
import type { MockConversationStore } from './conversation.js';
import { ulid } from './conversation.js';

/**
 * In-memory implementation of the `Assistant::Turn` storage service.
 *
 * Mirrors `src/assistant/turn.cr`: `idx` is computed via `MAX(idx)+1` per
 * conversation, `Conversation.touch` is invoked on insert to keep the
 * parent's `updated_at` in step, and `Conversation.unarchive` clears the
 * archive flag — a new turn unarchives an archived conversation, same
 * contract as the backend. Rows it inserts are terminal (`done`);
 * `MockStreamSession` opens its own `running` row and completes it,
 * mirroring `Turn.open` + `Turn.complete`.
 */
export class MockTurnStore {
	private readonly rows = new Map<string, Turn>();

	constructor(private readonly conversations: MockConversationStore) {}

	create(
		conversationId: string,
		fields: {
			request_messages: Turn['request_messages'];
			response_messages: Turn['response_messages'];
			usage: Turn['usage'];
			status?: Turn['status'];
			finish_reason?: string | null;
			error?: string | null;
		}
	): Turn {
		const idx = this.nextIdx(conversationId);
		const row: Turn = {
			id: ulid(),
			conversation_id: conversationId,
			idx,
			request_messages: fields.request_messages,
			response_messages: fields.response_messages,
			status: fields.status ?? 'done',
			usage: fields.usage,
			finish_reason: fields.finish_reason ?? null,
			error: fields.error ?? null,
			created_at: new Date().toISOString()
		};
		this.rows.set(row.id, row);
		this.conversations.touch(conversationId);
		this.conversations.unarchive(conversationId);
		return row;
	}

	/** Flips a row to its terminal state — the mock's `Turn.complete`. */
	complete(
		turnId: string,
		fields: {
			response_messages: Turn['response_messages'];
			usage: Turn['usage'];
			status: Turn['status'];
			finish_reason?: string | null;
			error?: string | null;
		}
	): void {
		const row = this.rows.get(turnId);
		if (!row) return;
		row.response_messages = fields.response_messages;
		row.usage = fields.usage;
		row.status = fields.status;
		row.finish_reason = fields.finish_reason ?? null;
		row.error = fields.error ?? null;
	}

	/**
	 * Stores the running row's partial exchange. Mirrors `Turn.checkpoint` on
	 * the backend: the row must exist and still be `running` — a terminal row
	 * never rewrites its messages. A no-op otherwise.
	 */
	checkpoint(turnId: string, responseMessages: Turn['response_messages']): void {
		const row = this.rows.get(turnId);
		if (!row || row.status !== 'running') return;
		row.response_messages = responseMessages;
	}

	/** The conversation's running row, or `null` — the mock's `Turn.running_turn`. */
	runningTurn(conversationId: string): Turn | null {
		return this.list(conversationId).find((r) => r.status === 'running') ?? null;
	}

	/** The latest row, or `null` — the mock's `Turn.latest` summary. */
	latest(conversationId: string): TurnSummary | null {
		const rows = this.list(conversationId);
		const last = rows[rows.length - 1];
		if (!last) return null;
		return {
			id: last.id,
			idx: last.idx,
			status: last.status,
			finish_reason: last.finish_reason,
			error: last.error,
			request_messages: last.request_messages,
			response_messages: last.response_messages,
			created_at: last.created_at
		};
	}

	list(conversationId: string): Turn[] {
		return Array.from(this.rows.values())
			.filter((r) => r.conversation_id === conversationId)
			.sort((a, b) => a.idx - b.idx);
	}

	private nextIdx(conversationId: string): number {
		let max = 0;
		for (const row of this.rows.values()) {
			if (row.conversation_id === conversationId && row.idx > max) max = row.idx;
		}
		return max + 1;
	}
}
