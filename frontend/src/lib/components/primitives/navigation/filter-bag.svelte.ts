// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Session-local reactive clone of a story `filters` map — the same contract
 * as `sessionBag` (DVT stories). FilterBar is controlled: the story must
 * reflect each `onFilterChange` emission back into the rendered map, or the
 * chip controls revert on the next render. A map passed straight from
 * `args` would turn every write into a deep write through the Storybook
 * args proxy; the clone severs that shared reference. The helpers live in
 * this `.svelte.ts` module because the stories CSF indexer rejects runes in
 * the stories file's module script (see the workflow doc's story rules).
 */

/** A fresh reactive clone of `filters` — call it from the story template. */
export function filterBag(filters: Record<string, unknown>): Record<string, unknown> {
	const clone: Record<string, unknown> = { ...filters };
	for (const key of Object.keys(clone)) {
		const v = clone[key];
		if (Array.isArray(v)) clone[key] = [...v];
	}
	const reactive = $state(clone);
	return reactive;
}

/** Replace the bag's contents with the next filter map (same keys only). */
export function replaceBag(bag: Record<string, unknown>, next: Record<string, unknown>): void {
	for (const k of Object.keys(bag)) delete bag[k];
	Object.assign(bag, next);
}
