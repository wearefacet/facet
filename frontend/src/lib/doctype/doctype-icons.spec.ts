// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { searchDoctypeIcons, resolveDoctypeIcon, DOCTYPE_DEFAULT_ICON } from './doctype-icons.js';

describe('doctype-icons — virtual in-memory catalog', () => {
	it('resolves a known kebab-case value to a component', () => {
		const Icon = resolveDoctypeIcon('building-2');
		expect(Icon).toBeTypeOf('function');
	});

	it('falls back to the default (diamond) icon for unknown or empty values', () => {
		expect(resolveDoctypeIcon(undefined)).toBe(DOCTYPE_DEFAULT_ICON);
		expect(resolveDoctypeIcon(null)).toBe(DOCTYPE_DEFAULT_ICON);
		expect(resolveDoctypeIcon('')).toBe(DOCTYPE_DEFAULT_ICON);
		expect(resolveDoctypeIcon('this-icon-does-not-exist')).toBe(DOCTYPE_DEFAULT_ICON);
		expect(DOCTYPE_DEFAULT_ICON).toBeTypeOf('function');
	});

	it('returns an empty query first page and a total', async () => {
		const page = await searchDoctypeIcons('');
		expect(page.options.length).toBeGreaterThan(0);
		expect(page.total).toBeGreaterThanOrEqual(page.options.length);
		// Every option carries a kebab-case value, human label, and component.
		for (const opt of page.options) {
			expect(opt.value).toMatch(/^[a-z0-9-]+$/);
			expect(opt.label.length).toBeGreaterThan(0);
			expect(opt.icon).toBeTypeOf('function');
		}
	});

	it('filters by substring on value and label', async () => {
		const page = await searchDoctypeIcons('building');
		expect(page.total).toBeGreaterThan(0);
		for (const opt of page.options) {
			const hay = `${opt.value} ${opt.label}`.toLowerCase();
			expect(hay).toContain('building');
		}
	});

	it('paginates: subsequent pages continue and eventually exhaust', async () => {
		const { options: first, next: c1, total } = await searchDoctypeIcons('', null, 10);
		expect(first.length).toBe(10);
		expect(c1).not.toBeNull();

		const { options: second } = await searchDoctypeIcons('', c1, 10);
		expect(second.length).toBe(10);
		expect(second[0].value).not.toBe(first[0].value);

		// Walk from the first page's cursor to the end to confirm `next`
		// becomes null after `total` items.
		let cursor: string | null = c1;
		let seen = first.length;
		let guard = 0;
		do {
			const page = await searchDoctypeIcons('', cursor, 10);
			seen += page.options.length;
			cursor = page.next;
			guard++;
			if (guard > 10000) throw new Error('pagination did not terminate');
		} while (cursor != null);
		expect(seen).toBe(total);
	});

	it('keeps the filter while paging', async () => {
		// `arrow` matches enough icons (86) to page with a page size of 3.
		const first = await searchDoctypeIcons('arrow', null, 3);
		const second = await searchDoctypeIcons('arrow', first.next, 3);
		const values = new Set([...first.options, ...second.options].map((o) => o.value));
		expect(values.size).toBe(first.options.length + second.options.length);
		for (const opt of second.options) {
			expect(opt.value).toContain('arrow');
		}
	});
});
