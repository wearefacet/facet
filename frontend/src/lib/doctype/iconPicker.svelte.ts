// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Icon-picker state machine for the doctype settings tab.
 *
 * The icon catalog is large (Lucide ~1700 icons) and is served through the
 * async mode of `Select`: we search an in-memory "virtual backend" that
 * returns results page-by-page, and append the next page as the dropdown
 * scrolls instead of eagerly rendering every icon. See `doctype-icons.ts`.
 *
 * One factory instance per editor. The sequence guard and the busy flag are
 * plain closure variables — they guard async bookkeeping, not rendered state.
 */

import { searchDoctypeIcons, type DoctypeIconOption } from './doctype-icons.js';

export type IconPicker = ReturnType<typeof createIconPicker>;

export function createIconPicker() {
	let results = $state<DoctypeIconOption[]>([]);
	let cursor = $state<string | null>(null);
	let seq = 0; // guards against out-of-order async responses
	let nextPageBusy = false; // non-$state; prevents concurrent scroll appends
	let query = ''; // last issued query, reused when appending the next page

	async function search(q: string) {
		const my = ++seq;
		query = q;
		try {
			const page = await searchDoctypeIcons(q, null);
			if (my !== seq) return;
			results = page.options;
			cursor = page.next;
		} finally {
			void my;
		}
	}

	async function loadMore() {
		if (nextPageBusy || cursor == null) return;
		const pageCursor = cursor;
		const q = query; // keep the same filter when paging
		nextPageBusy = true;
		const my = ++seq;
		try {
			const page = await searchDoctypeIcons(q, pageCursor);
			if (my !== seq) return;
			results = [...results, ...page.options];
			cursor = page.next;
		} finally {
			nextPageBusy = false;
		}
	}

	function onMenuScroll(e: Event) {
		// When the user scrolls near the bottom of the dropdown viewport, fetch
		// the next page of icons and append it to the visible list.
		const el = e.target as HTMLElement;
		if (el.scrollTop + el.clientHeight >= el.scrollHeight - 40) {
			loadMore();
		}
	}

	return {
		get results(): DoctypeIconOption[] {
			return results;
		},
		get cursor(): string | null {
			return cursor;
		},
		search,
		loadMore,
		onMenuScroll
	};
}
