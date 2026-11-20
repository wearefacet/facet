// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Runes store holding the currency set for the money display and picker
 * surfaces: one list fetch of `core.Currency` documents per session.
 *
 * Exposed through `useCurrencies()`:
 *
 * - `all` — every seeded row, ticker ascending (any state — including
 *   inactive rows, so stored values keep resolving after deactivation);
 * - `favorites` — `favorite` rows, ticker ascending: the picker's top group;
 * - `active` — active, non-favorite rows, ticker ascending: the picker's
 *   main group;
 * - `resolve(ticker)` — any row by ticker, active or not. Inactive rows
 *   surface only here (stored values stay resolvable; the picker never
 *   offers them).
 *
 * ## Fetch lifecycle
 *
 * The list fetches once per session: the first `useCurrencies()` call in the
 * browser starts it, and a settled attempt (success **or** failure) is never
 * retried — a failed fetch leaves the store empty and callers degrade (the
 * picker falls back to the current ticker, the display to bare-ticker
 * labels). The session state clears via `invalidateAllClientCaches` on
 * logout and role switches, so the next session re-fetches from scratch.
 *
 * ## Test seam
 *
 * `seedCurrencies(rows)` replaces the row set synchronously and marks the
 * store settled — stories and tests use it instead of the API (they seed the
 * rows out of the mock driver's `core.Currency` documents; the mock seed
 * pipeline loads them from `data/seeds/core.Currency/`). It must only run
 * outside a Svelte reaction: the preview seeds from a project loader (before
 * the render), and a story that needs a different row set seeds from the top
 * of its play function (after the render).
 */
import { DocumentDataSource } from '$lib/datasource/DocumentDataSource.js';
import { onInvalidateAllClientCaches } from '$lib/datasource/clientCache.js';
import type { MockDataDriver } from '$lib/datasource/MockDriver.js';
import type { CurrencyDef } from './currencies.js';

export interface CurrencyRecord extends CurrencyDef {
	/** Display glyph (`€`). An empty symbol renders the bare ticker. */
	symbol: string;
	/** English currency name (`Euro`). */
	name: string;
	/** Digit-grouping style: `standard` thousands, `lakhs` Indian `1,00,000`. */
	grouping: 'standard' | 'lakhs';
	/** Visible and selectable when true. */
	active: boolean;
	/** Pinned to the top of the picker when true. */
	favorite: boolean;
}

/** One picker option, tagged with its group kind for header rendering. */
export interface CurrencyPick {
	row: CurrencyRecord;
	/** Option represents the currently-stored ticker (inactive or unknown). */
	flagged: boolean;
	/** Set on the first option of the favorites group — rendered as a header. */
	groupLabel?: string;
}

/** The picker list caps at 500 rows — far above the ~150 circulating currencies. */
const MAX_ITEMS = 500;

const BROWSER = typeof window !== 'undefined';

// ── Session state (module-level runes) ──────────────────────────────────────

let rows = $state<CurrencyRecord[]>([]);
/** True once a fetch attempt has settled this session (success or failure). */
let settled = $state(false);
let inflight: Promise<void> | null = null;
/**
 * Session fence. Bumped by the cache-invalidation hook so an in-flight fetch
 * from the previous session (logout / role switch landed mid-request) can
 * no longer write its stale response into the new session's state.
 */
let generation = 0;

const byTicker = (a: CurrencyRecord, b: CurrencyRecord) => a.ticker.localeCompare(b.ticker);

const all = $derived([...rows].sort(byTicker));
const favorites = $derived(rows.filter((r) => r.favorite && r.active).sort(byTicker));
const active = $derived(rows.filter((r) => r.active && !r.favorite).sort(byTicker));

function resolve(ticker: string): CurrencyRecord | undefined {
	return rows.find((r) => r.ticker === ticker);
}

// ── Store API ───────────────────────────────────────────────────────────────

export interface Currencies {
	readonly all: CurrencyRecord[];
	readonly favorites: CurrencyRecord[];
	readonly active: CurrencyRecord[];
	resolve(ticker: string): CurrencyRecord | undefined;
}

/**
 * Store access for the money surfaces. Starts the session fetch on the first
 * browser call; on the server (SSR) it returns the empty store — callers
 * render the fallback and re-render once the client fetch lands.
 */
export function useCurrencies(): Currencies {
	if (BROWSER && !settled && inflight === null) load();
	return {
		get all() {
			return all;
		},
		get favorites() {
			return favorites;
		},
		get active() {
			return active;
		},
		resolve
	};
}

// ── Fetch ───────────────────────────────────────────────────────────────────

function load(): void {
	const gen = generation;
	inflight = new DocumentDataSource<Record<string, unknown>>('core', 'Currency')
		.list({ items: MAX_ITEMS })
		.then((res) => {
			// A logout / role switch during the request starts a new session —
			// the stale session's response never lands.
			if (gen !== generation) return;
			rows = currencyRowsFromDocuments(res.data);
			settled = true;
		})
		.catch(() => {
			// Failed fetch — the store stays empty and callers degrade. No
			// retry this session (one list fetch per session, by contract).
			if (gen !== generation) return;
			settled = true;
		})
		.finally(() => {
			// Same fence: a superseded request must not null the newer
			// attempt's in-flight reference.
			if (gen === generation) inflight = null;
		});
}

// Logout / role switch drop the session state with the other client caches.
onInvalidateAllClientCaches(() => {
	generation++;
	rows = [];
	settled = false;
	inflight = null;
});

// ── Row mapping ─────────────────────────────────────────────────────────────

/**
 * Maps document records to currency rows. Accepts both response shapes the
 * surfaces see: an API list item (`{ data: content, meta }`) or a flat mock
 * document (`{ id, ...content }`) — the content is whichever of the two the
 * record actually carries. Field defaults mirror the `core.Currency` doctype
 * (`active: true`, `favorite: false`, `grouping: standard`); rows without a
 * ticker are dropped (never selectable, never resolvable).
 */
export function currencyRowsFromDocuments(docs: Array<Record<string, unknown>>): CurrencyRecord[] {
	const out: CurrencyRecord[] = [];
	for (const doc of docs) {
		const content = isListEntry(doc) ? doc.data : doc;
		if (!content || typeof content !== 'object') continue;
		const c = content as Record<string, unknown>;
		if (typeof c.ticker !== 'string' || c.ticker === '') continue;
		out.push({
			ticker: c.ticker,
			symbol: typeof c.symbol === 'string' ? c.symbol : '',
			name: typeof c.name === 'string' ? c.name : '',
			digits: typeof c.digits === 'number' ? c.digits : 2,
			grouping: c.grouping === 'lakhs' ? 'lakhs' : 'standard',
			active: c.active !== false,
			favorite: c.favorite === true
		});
	}
	return out;
}

function isListEntry(doc: Record<string, unknown>): boolean {
	return !!doc && typeof doc === 'object' && 'data' in doc;
}

// ── Test seam ───────────────────────────────────────────────────────────────

/**
 * Replaces the row set synchronously (stories, unit tests) and marks the
 * store settled — the session fetch never starts. The Storybook preview
 * loader seeds the rows before every story; a story that needs a different
 * row set (empty store, an inactive row) seeds its own from the top of its
 * play function, which runs after the render and overrides the loader.
 *
 * Never call this from inside a template expression or a decorator: state
 * writes are forbidden within a Svelte render reaction.
 */
export function seedCurrencies(seeded: CurrencyRecord[]): void {
	rows = seeded;
	settled = true;
	inflight = null;
}

/**
 * Maps a mock driver's `core.Currency` documents (loaded from
 * `data/seeds/core.Currency/`) to store rows — the story-side of the seam.
 */
export function currencyRowsFromMockDriver(driver: MockDataDriver): CurrencyRecord[] {
	const contents: Record<string, unknown>[] = [];
	for (const doc of driver.docs.values()) {
		if (typeof doc !== 'object' || doc === null) continue;
		const rec = doc as Record<string, unknown>;
		if (rec.domain !== 'core' || rec.doc_type !== 'Currency') continue;
		if (typeof rec.content === 'object' && rec.content !== null) {
			contents.push(rec.content as Record<string, unknown>);
		}
	}
	return currencyRowsFromDocuments(contents);
}
