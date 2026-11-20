// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Schematic layout persistence helpers.
 *
 * Pure logic for the `core.SchematicLayout` round-trip: parse the stored
 * positions map out of a document, merge it over the deterministic layout
 * the doctype adapter computes, build the full payload for a save, and
 * debounce the saves. The HTTP access lives in `./layoutSource.ts` — this
 * module stays free of any fetch dependency so the Vitest server project
 * can test it directly.
 *
 * Contract (doc/frontend/schematic.md → Persistence):
 *
 * - One `core.SchematicLayout` document per target domain, found by its
 *   `domain` field (the UI creates the row lazily on the first save, so
 *   the row id is a server-assigned ULID).
 * - `positions` is a dictionary keyed by the domain's qualified doctype
 *   ids, each value `{x, y}` in schematic pixels (integers).
 * - Stored positions win over the computed layout; entries whose doctype
 *   no longer exists are ignored.
 * - Saves write the full map (last write wins between arrangers).
 */

/** Running or stored positions, keyed by qualified doctype id. */
export type SchematicPositions = Record<string, { x: number; y: number }>;

/** Content shape of a `core.SchematicLayout` document. */
export interface SchematicLayoutContent {
	domain?: string;
	positions?: Record<string, { x?: unknown; y?: unknown }> | null;
}

/** A layout source — where the positions live. The stories swap in a mock. */
export interface SchematicLayoutSource {
	/** Stored positions for `domain`, or null when no document exists yet. */
	load(domain: string): Promise<SchematicPositions | null>;
	/** Write the full positions map for `domain` (create on first save). */
	save(domain: string, positions: SchematicPositions): Promise<void>;
}

/** True when `v` is a finite number (positions arrive from the network). */
function isFiniteNumber(v: unknown): v is number {
	return typeof v === 'number' && Number.isFinite(v);
}

/**
 * Extract the stored positions map from a document's content. Entries with
 * a malformed or non-finite x/y are dropped. Returns null when the content
 * carries no usable map (missing document, empty or malformed positions).
 */
export function parseStoredPositions(content: unknown): SchematicPositions | null {
	const c = content as SchematicLayoutContent | null | undefined;
	if (!c || typeof c !== 'object' || !c.positions || typeof c.positions !== 'object') {
		return null;
	}
	const out: SchematicPositions = {};
	for (const [key, value] of Object.entries(c.positions)) {
		if (!value || typeof value !== 'object') continue;
		const { x, y } = value as { x?: unknown; y?: unknown };
		if (!isFiniteNumber(x) || !isFiniteNumber(y)) continue;
		out[key] = { x, y };
	}
	return Object.keys(out).length > 0 ? out : null;
}

/**
 * Merge stored positions over the computed layout. A node whose qualified
 * id has a stored entry keeps the stored corner; every other node keeps
 * its computed position. Stored keys with no matching node are ignored
 * (the doctype no longer exists in the domain).
 */
export function mergePositions(
	nodes: { id: string; x: number; y: number }[],
	stored: SchematicPositions | null | undefined
): SchematicPositions {
	const out: SchematicPositions = {};
	for (const n of nodes) {
		const s = stored?.[n.id];
		out[n.id] =
			s && isFiniteNumber(s.x) && isFiniteNumber(s.y) ? { x: s.x, y: s.y } : { x: n.x, y: n.y };
	}
	return out;
}

/**
 * Build the full save payload from the live positions of `nodes`,
 * rounded to integers (the schema stores integers; drag deltas are
 * sub-pixel floats). Keys follow the nodes — stale entries are dropped.
 */
export function positionsPayload(
	nodes: { id: string }[],
	positions: SchematicPositions
): SchematicPositions {
	const out: SchematicPositions = {};
	for (const n of nodes) {
		const p = positions[n.id];
		if (!p || !isFiniteNumber(p.x) || !isFiniteNumber(p.y)) continue;
		out[n.id] = { x: Math.round(p.x), y: Math.round(p.y) };
	}
	return out;
}

export interface LayoutSaver {
	/** Schedule a save `delayMs` after the last schedule call. The domain
	 *  is captured at schedule time — a domain switch drops the pending save
	 *  instead of writing the old layout onto the new domain. */
	schedule(domain: string, positions: SchematicPositions): void;
	/** Drop a pending save (component teardown, domain switch). */
	cancel(): void;
}

/**
 * Coalesce rapid saves into one trailing call: each `schedule` resets the
 * timer, so a burst of drag-ends within `delayMs` fires `save` once, with
 * the last positions and the domain it was scheduled for. Save failures
 * surface through the returned promise rejection — callers decide how to
 * report them.
 */
export function createLayoutSaver(
	save: (domain: string, positions: SchematicPositions) => Promise<void>,
	delayMs = 500
): LayoutSaver {
	let timer: ReturnType<typeof setTimeout> | null = null;
	let pending: { domain: string; positions: SchematicPositions } | null = null;

	const flush = async () => {
		timer = null;
		const p = pending;
		pending = null;
		if (p) await save(p.domain, p.positions);
	};

	return {
		schedule(domain, positions) {
			pending = { domain, positions };
			if (timer) clearTimeout(timer);
			timer = setTimeout(() => void flush(), delayMs);
		},
		cancel() {
			if (timer) clearTimeout(timer);
			timer = null;
			pending = null;
		}
	};
}
