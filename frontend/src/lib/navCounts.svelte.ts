// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Lazy per-doctype document counts for the sidebar.
 *
 * `buildNavModel` returns doctypes with `count: undefined` — the badges are
 * filled in here, on demand, when a domain becomes active in `NavPanel`. This
 * keeps `buildNavModel` a pure data-shape pass: no per-doctype
 * `aggregate=count` round-trips fire for domains the user never opens.
 *
 * Mirrors the pattern of `navState.svelte.ts`, `permissions.svelte.ts`, and
 * `theme.svelte.ts`: module-level `$state`, getter/setter functions, no
 * `setContext` (see `doc/frontend/workflow.md` → "Never use setContext /
 * getContext"). The fetch is async, so it cannot be a `$derived` — it lives
 * behind an explicit `loadForDomain` call the sidebar triggers from an effect.
 *
 * The HTTP request goes through `apiFetch`, so a re-toggle of the same domain
 * within the same SvelteKit session reuses the browser's HTTP cache and the
 * backend's 304-on-ETag path. This module adds an in-memory dedup layer
 * (one fetch per doctype at a time), and `counts` holds each resolved value
 * until an invalidation drops it or logout clears the store.
 *
 * Invalidation: an import writes documents out-of-band, so cached counts go
 * stale. `invalidateCount` (one doctype) and `clearDomainCounts` (one whole
 * domain) drop the cached values and bump a version counter the `NavPanel`
 * fetch effect reads — the effect re-runs without a navigation, and
 * `loadForDomain` refetches only the dropped entries. A fetch already in
 * flight when the invalidation lands is stale: every fetch carries a
 * per-doctype token, and a result whose token is no longer the newest is
 * dropped instead of written, so a pre-import count cannot overwrite the
 * invalidation.
 *
 * Why a plain object, not a `Map`: Svelte 5's `$state` proxy tracks per-key
 * reads on objects via property access (`counts[qualified]`), which is the
 * shape the rest of the codebase's reactive stores use (`permissions`,
 * `navState`). A `Map`'s `.get()`/`.set()` go through the proxy's *method*
 * trapping path, which we found does not reliably propagate writes fired
 * inside an async callback through to template reads — the badge stayed on
 * `—` even though `getCount(qualified)` returned the resolved number. Using
 * a plain object keyed by qualified name (reassigned wholesale on each update)
 * routes notifications through the variable's top-level signal — the same
 * mechanism that makes `permissions.svelte.ts`'s `can()` re-render `<Can>`
 * without a `$derived` wrapper.
 */

import { untrack } from 'svelte';
import type { DataDriver } from './datasource/driver.js';
import type { NavDoctype } from './navTypes';

/**
 * Qualified doctype name → cached count. `undefined` means "not fetched yet",
 * `0` means "fetched and empty". Whole-object reassignment on each resolved
 * count so consumers' reactive reads of `counts[qualified]` re-evaluate.
 */
let counts: Record<string, number> = $state({});

/**
 * Bumped by every invalidation. The `NavPanel` fetch effect reads it, so an
 * invalidation re-arms the fetch while the user stays on the same page.
 */
let version = $state(0);

/**
 * Per-doctype fetch tokens. `loadForDomain` issues the next token for every
 * doctype it fetches; an invalidation issues one too, which marks any earlier
 * fetch for that doctype stale — its result is dropped, and its in-flight
 * marker no longer blocks a refetch.
 */
const tokens = new Map<string, number>();

/** Qualified doctype name → token of the count fetch in flight. */
// The maps above are bookkeeping, not render state; consumers react via the
// `counts` reassignment and the `version` bump instead. Reads stay untracked
// so a caller inside an effect does not subscribe to them (workflow.md →
// "The equality-guard trap in writeback effects").
const inFlight = new Map<string, number>();

function nextToken(qualified: string): number {
	const next = (tokens.get(qualified) ?? 0) + 1;
	tokens.set(qualified, next);
	return next;
}

/** A fetch blocks a refetch only while its marker carries the newest token —
 *  an invalidation (token bump) frees the slot for a refetch. */
function inFlightCurrent(qualified: string): boolean {
	const marker = inFlight.get(qualified);
	return marker !== undefined && marker === tokens.get(qualified);
}

/**
 * Splits `"domain.Doctype"` into its `"domain"` segment.
 */
function domainOf(qualified: string): string {
	const dot = qualified.indexOf('.');
	return qualified.slice(0, dot);
}

/**
 * Splits `"domain.Doctype"` into its `"Doctype"` segment — the name the
 * DataSource API expects (not the display label, which may differ from the
 * underlying doctype id in future revisions).
 */
function doctypeOf(qualified: string): string {
	const dot = qualified.indexOf('.');
	return qualified.slice(dot + 1);
}

/**
 * Returns the cached count for the given qualified doctype, or `undefined`
 * when it has not been fetched yet. The sidebar renders `—` until the
 * promise for the active domain's counts resolves.
 */
export function getCount(qualified: string): number | undefined {
	return counts[qualified];
}

/**
 * The store's invalidation version. `NavPanel` reads it inside its fetch
 * effect: a bump re-runs the effect with no domain change, and the pending
 * filter in `loadForDomain` refetches only the dropped entries.
 */
export function getCountsVersion(): number {
	return version;
}

/**
 * Issues `aggregate=count` calls in parallel for the given doctypes, writing
 * the results into the shared `counts` object. Idempotent: doctypes already
 * resolved or with a current fetch in flight are skipped, so calling this on
 * every domain switch is cheap.
 *
 * Errors are swallowed per-doctype — a failure leaves that doctype's count
 * `undefined` (badge shows `—`) without aborting the rest of the wave.
 */
export async function loadForDomain(driver: DataDriver, doctypes: NavDoctype[]): Promise<void> {
	const pending = untrack(() =>
		doctypes.filter((dt) => counts[dt.qualified] === undefined && !inFlightCurrent(dt.qualified))
	);
	if (pending.length === 0) return;

	await Promise.all(
		pending.map(async (dt) => {
			// Mark before the first await: the marker must exist by the time
			// loadForDomain returns, or a concurrent call would double-fetch.
			const token = untrack(() => {
				const t = nextToken(dt.qualified);
				inFlight.set(dt.qualified, t);
				return t;
			});
			try {
				const result = await driver
					.domain(domainOf(dt.qualified))
					.doctype(doctypeOf(dt.qualified))
					.list({ aggregate: 'count' });
				untrack(() => {
					// An invalidation since the fetch started makes this result
					// stale — drop it; the version bump re-armed the refetch.
					if (tokens.get(dt.qualified) !== token) return;
					counts = { ...counts, [dt.qualified]: result.meta.count };
				});
			} catch {
				// Swallow per-doctype errors: a single failing count leaves
				// the badge `undefined` (renders as `—`) without aborting
				// the rest of the wave.
			} finally {
				// Release only a marker this fetch still owns — a newer
				// fetch's marker stays until that fetch finishes.
				untrack(() => {
					if (inFlight.get(dt.qualified) === token) inFlight.delete(dt.qualified);
				});
			}
		})
	);
}

/**
 * Drops one doctype's cached count so the next `loadForDomain` refetches it,
 * and bumps the version so the sidebar's fetch effect re-arms without a
 * navigation. Call after a write lands out-of-band — the doctype page's
 * row-import completion callback is the current caller.
 */
export function invalidateCount(qualified: string): void {
	untrack(() => {
		nextToken(qualified);
		if (counts[qualified] !== undefined) {
			const next = { ...counts };
			delete next[qualified];
			counts = next;
		}
		version++;
	});
}

/**
 * Drops every cached count for one domain's doctypes (qualified names that
 * start with `"{domain}."`) and bumps the version so the sidebar refetches —
 * including doctypes the model gained that were never counted. Call after a
 * domain-bundle import; the import report's `domain` names the target domain.
 */
export function clearDomainCounts(domain: string): void {
	untrack(() => {
		const prefix = `${domain}.`;
		const next = { ...counts };
		let dropped = false;
		for (const qualified of Object.keys(counts)) {
			if (!qualified.startsWith(prefix)) continue;
			nextToken(qualified);
			delete next[qualified];
			dropped = true;
		}
		// A fetch still in flight holds no cached value — bump its token too,
		// so its late result cannot reinstall a pre-import count.
		for (const qualified of inFlight.keys()) {
			if (qualified.startsWith(prefix)) nextToken(qualified);
		}
		if (dropped) counts = next;
		version++;
	});
}

/** Clears every cached count. Called on logout alongside
 *  `invalidateAllClientCaches` so the next login (possibly as a different
 *  user) re-fetches counts under the new RBAC scope. The version stays — the
 *  sidebar unmounts with the session, and a re-mount refetches anyway. */
export function clearCounts(): void {
	counts = {};
	tokens.clear();
	inFlight.clear();
}
