// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect, vi, afterEach } from 'vitest';
import type { Component } from 'svelte';
import { createIconPicker } from './iconPicker.svelte.js';
import { searchDoctypeIcons, type DoctypeIconPage } from './doctype-icons.js';

// The picker routes every catalog read through `searchDoctypeIcons`; the mock
// stands in for the in-memory Lucide backend so each test controls page timing.
vi.mock('./doctype-icons.js', () => ({ searchDoctypeIcons: vi.fn() }));

const ICON = (() => null) as unknown as Component;

function page(values: string[], next: string | null): DoctypeIconPage {
	return {
		options: values.map((value) => ({ value, label: value, icon: ICON })),
		next,
		total: values.length
	};
}

interface DeferredPage {
	promise: Promise<DoctypeIconPage>;
	resolve: (page: DoctypeIconPage) => void;
	reject: (err: unknown) => void;
}

/** Queue one deferred page per `searchDoctypeIcons` call, resolved by the test. */
function stubDeferredPages(): DeferredPage[] {
	const queue: DeferredPage[] = [];
	vi.mocked(searchDoctypeIcons).mockImplementation(() => {
		let resolve!: DeferredPage['resolve'];
		let reject!: DeferredPage['reject'];
		const promise = new Promise<DoctypeIconPage>((res, rej) => {
			resolve = res;
			reject = rej;
		});
		queue.push({ promise, resolve, reject });
		return promise;
	});
	return queue;
}

/** Fake a scroll event on the dropdown viewport without a real DOM node. */
function scrollEvent(top: number, clientHeight: number, scrollHeight: number): Event {
	return {
		target: { scrollTop: top, clientHeight, scrollHeight }
	} as unknown as Event;
}

function values(picker: ReturnType<typeof createIconPicker>): string[] {
	return picker.results.map((option) => option.value);
}

describe('createIconPicker', () => {
	afterEach(() => {
		vi.resetAllMocks();
	});

	it('drops a stale search response that lands out of order', async () => {
		const queue = stubDeferredPages();
		const picker = createIconPicker();

		const stale = picker.search('a');
		const fresh = picker.search('b');
		expect(queue).toHaveLength(2);

		// The newest query resolves first and becomes the visible result set.
		queue[1].resolve(page(['b1', 'b2'], null));
		await fresh;
		expect(values(picker)).toEqual(['b1', 'b2']);
		expect(picker.cursor).toBeNull();

		// The stale response lands last and must not overwrite the fresh one.
		queue[0].resolve(page(['a1'], 'next'));
		await stale;
		expect(values(picker)).toEqual(['b1', 'b2']);
		expect(picker.cursor).toBeNull();
	});

	it('guards concurrent page loads and pages with the same query', async () => {
		const queue = stubDeferredPages();
		const picker = createIconPicker();

		const initial = picker.search('deal');
		queue[0].resolve(page(['d1'], '48'));
		await initial;
		expect(vi.mocked(searchDoctypeIcons)).toHaveBeenCalledTimes(1);
		expect(vi.mocked(searchDoctypeIcons)).toHaveBeenNthCalledWith(1, 'deal', null);
		expect(values(picker)).toEqual(['d1']);
		expect(picker.cursor).toBe('48');

		// Two scroll-triggered loadMore calls in one tick: only one page request.
		const first = picker.loadMore();
		const second = picker.loadMore();
		expect(vi.mocked(searchDoctypeIcons)).toHaveBeenCalledTimes(2);
		expect(vi.mocked(searchDoctypeIcons)).toHaveBeenNthCalledWith(2, 'deal', '48');

		queue[1].resolve(page(['d2'], null));
		await first;
		await second;
		expect(values(picker)).toEqual(['d1', 'd2']);
		expect(picker.cursor).toBeNull();
	});

	it('fetches the next page only within 40px of the dropdown bottom', async () => {
		const queue = stubDeferredPages();
		const picker = createIconPicker();

		const initial = picker.search('');
		queue[0].resolve(page(['i1'], '48'));
		await initial;
		expect(vi.mocked(searchDoctypeIcons)).toHaveBeenCalledTimes(1);

		// Far from the bottom: no fetch.
		picker.onMenuScroll(scrollEvent(0, 300, 1200));
		picker.onMenuScroll(scrollEvent(859, 300, 1200));
		expect(vi.mocked(searchDoctypeIcons)).toHaveBeenCalledTimes(1);

		// Boundary is inclusive: 860 + 300 === 1200 - 40.
		picker.onMenuScroll(scrollEvent(860, 300, 1200));
		expect(vi.mocked(searchDoctypeIcons)).toHaveBeenCalledTimes(2);

		queue[1].resolve(page(['i2'], null));
		await queue[1].promise;
		expect(values(picker)).toEqual(['i1', 'i2']);
	});

	it('does not fetch when the catalog is exhausted', async () => {
		const queue = stubDeferredPages();
		const picker = createIconPicker();

		const initial = picker.search('');
		queue[0].resolve(page(['only'], null));
		await initial;

		picker.onMenuScroll(scrollEvent(1000, 300, 1200));
		expect(vi.mocked(searchDoctypeIcons)).toHaveBeenCalledTimes(1);
		expect(values(picker)).toEqual(['only']);
	});
});
