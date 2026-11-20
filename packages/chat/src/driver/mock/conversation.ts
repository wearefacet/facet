// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import type {
	Conversation,
	CreateConversationInput,
	ListConversationsParams,
	ListConversationsResult
} from '../types.js';

/**
 * In-memory implementation of the `Assistant::Conversation` storage service.
 *
 * Mirrors `src/assistant/conversation.cr`: stateful, holds rows in a `Map`,
 * and computes ULIDs and timestamps locally. Used by `MockAssistantDriver`
 * (the analog of `Assistant::Routes`) for create/find/list/touch, plus the
 * archive state (`setArchived` / `unarchive`) and its list visibility.
 */
export class MockConversationStore {
	private readonly rows = new Map<string, Conversation>();

	create(input: CreateConversationInput): Conversation {
		const now = new Date().toISOString();
		const conv: Conversation = {
			id: ulid(),
			session_id: ulid(),
			cache_key: ulid(),
			system_prompt: 'You are a helpful assistant.',
			context: input.context ?? {},
			enabled_tools: input.enabled_tools ?? [],
			created_at: now,
			updated_at: now,
			archived_at: null
		};
		this.rows.set(conv.id, conv);
		return conv;
	}

	find(id: string): Conversation | null {
		return this.rows.get(id) ?? null;
	}

	/**
	 * Lists conversations with filtering, sorting, and pagination.
	 *
	 * Mirrors `Assistant::Conversation.list` on the backend:
	 * - Default sort is `-updated_at`.
	 * - Live rows only, unless `archived__eq=true` asks for the archived ones —
	 *   same archive visibility as the backend.
	 * - `context.<key>__eq` filters apply jsonb-equality semantics (simple
	 *   deep-equality check on the stored `context` object).
	 * - `<column>__op` filters on `id`/`session_id`/`cache_key`/`model` work
	 *   for `eq`/`ne`/`match` (string ILIKE). `created_at`/`updated_at` work
	 *   for `eq`/`ne`/`gt`/`gte`/`lt`/`lte` (ISO-8601 string comparison).
	 * - `page`/`items` paginate. `meta.more` is `true` when more rows exist
	 *   past the current page, matching the backend's capped-count strategy.
	 */
	list(params?: ListConversationsParams): ListConversationsResult {
		const items = params?.items ?? 100;
		const page = params?.page ?? 1;
		const sort = params?.sort && params.sort.length ? params.sort : ['-updated_at'];
		const filters = params?.filters ?? {};

		let rows = Array.from(this.rows.values());
		rows = this.applyFilters(rows, filters);
		rows = this.applySort(rows, sort);

		const offset = (page - 1) * items;
		const total = rows.length;
		const slice = rows.slice(offset, offset + items);
		const more = offset + items < total;

		return {
			data: slice,
			meta: {
				count: Math.min(offset + items, total),
				more
			}
		};
	}

	touch(id: string): void {
		const row = this.rows.get(id);
		if (!row) return;
		row.updated_at = new Date().toISOString();
	}

	/** Stamps or clears the archive state; returns the updated row or `null`
	 * for an unknown id — the mock's `Conversation.set_archived`. */
	setArchived(id: string, archived: boolean): Conversation | null {
		const row = this.rows.get(id);
		if (!row) return null;
		row.archived_at = archived ? new Date().toISOString() : null;
		return row;
	}

	/** Clears the archive flag when set — the mock's `Conversation.unarchive`,
	 * called by the turn insert so activity unarchives a conversation. A
	 * no-op for a live conversation. */
	unarchive(id: string): void {
		const row = this.rows.get(id);
		if (!row) return;
		row.archived_at = null;
	}

	/** Test helper: directly inserts a row (skipping validation). */
	seed(conv: Conversation): void {
		this.rows.set(conv.id, conv);
	}

	// ── Private ──────────────────────────────────────────────────────────

	private applyFilters(
		rows: Conversation[],
		filters: Record<string, string | number | boolean>
	): Conversation[] {
		// Archive visibility first — live-only unless `archived__eq=true`.
		const wantArchived = String(filters['archived__eq'] ?? '') === 'true';
		rows = rows.filter((conv) => (conv.archived_at != null) === wantArchived);

		if (Object.keys(filters).length === 0) return rows;

		// Partition filters into context filters and column filters. The
		// archive key is handled above — it must not land in the column
		// partition, where `archived` is an unknown column.
		const contextFilters: Record<string, string> = {};
		const columnFilters: Record<string, string> = {};
		for (const [key, value] of Object.entries(filters)) {
			if (key === 'archived__eq') continue;
			const [field] = key.split('__', 2);
			if (field!.startsWith('context.')) {
				contextFilters[key] = String(value);
			} else {
				columnFilters[key] = String(value);
			}
		}

		return rows.filter((conv) => {
			return this.matchesContext(conv, contextFilters) && this.matchesColumns(conv, columnFilters);
		});
	}

	private matchesContext(conv: Conversation, filters: Record<string, string>): boolean {
		for (const [key, value] of Object.entries(filters)) {
			const [field, op] = key.split('__', 2);
			if (op && op !== 'eq') continue; // Only `eq` supported on context.
			const ctxKey = field!.slice('context.'.length);
			if (!ctxKey) continue;
			const stored = conv.context[ctxKey];
			// jsonb containment equality: deep-equal on primitives.
			if (String(stored) !== value) return false;
		}
		return true;
	}

	private matchesColumns(conv: Conversation, filters: Record<string, string>): boolean {
		const sortable: Record<string, string> = {
			id: conv.id,
			session_id: conv.session_id,
			cache_key: conv.cache_key,
			created_at: conv.created_at,
			updated_at: conv.updated_at
		};

		for (const [key, value] of Object.entries(filters)) {
			const [field, op = 'eq'] = key.split('__', 2);
			const candidate = sortable[field!];
			if (candidate === undefined) return false;
			switch (op) {
				case 'eq':
					if (candidate !== value) return false;
					break;
				case 'ne':
					if (candidate === value) return false;
					break;
				case 'match':
					if (!candidate.toLowerCase().includes(value.toLowerCase())) return false;
					break;
				case 'gt':
					if (!(candidate > value)) return false;
					break;
				case 'gte':
					if (!(candidate >= value)) return false;
					break;
				case 'lt':
					if (!(candidate < value)) return false;
					break;
				case 'lte':
					if (!(candidate <= value)) return false;
					break;
				default:
					return false;
			}
		}
		return true;
	}

	private applySort(rows: Conversation[], sort: string[]): Conversation[] {
		const sortable: Record<string, (conv: Conversation) => string> = {
			id: (c) => c.id,
			created_at: (c) => c.created_at,
			updated_at: (c) => c.updated_at
		};

		const comparators = sort
			.map((spec) => {
				const dir = spec.startsWith('-') ? -1 : 1;
				const col = spec.startsWith('-') ? spec.slice(1) : spec;
				const accessor = sortable[col];
				if (!accessor) return null;
				return { dir, accessor };
			})
			.filter((c): c is { dir: number; accessor: (conv: Conversation) => string } => c !== null);

		if (comparators.length === 0) {
			// Default: updated_at DESC.
			return [...rows].sort((a, b) =>
				a.updated_at < b.updated_at ? 1 : a.updated_at > b.updated_at ? -1 : 0
			);
		}

		return [...rows].sort((a, b) => {
			for (const { dir, accessor } of comparators) {
				const av = accessor(a);
				const bv = accessor(b);
				if (av < bv) return -1 * dir;
				if (av > bv) return 1 * dir;
			}
			// Stable tiebreak on id ASC.
			return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
		});
	}
}

// ── ULID generator ────────────────────────────────────────────────────────────

/**
 * ULID generator (Crockford base32, time-sortable). Mirrors
 * `Util::ScriptHelpers.ulid` on the backend.
 */
export function ulid(): string {
	const time = Date.now();
	const ts = encodeTime(time);
	const rand = encodeRandom(10);
	return ts + rand;
}

const ENCODING = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

function encodeTime(ms: number): string {
	let out = '';
	let t = ms;
	for (let i = 9; i >= 0; i--) {
		const mod = Math.floor(t / Math.pow(32, i)) % 32;
		out = ENCODING[mod]! + out;
		t = t - mod * Math.pow(32, i);
	}
	return out;
}

function encodeRandom(len: number): string {
	let out = '';
	const bytes = new Uint8Array(len);
	crypto.getRandomValues(bytes);
	for (let i = 0; i < len; i++) {
		out += ENCODING[bytes[i]! % 32];
	}
	return out;
}
