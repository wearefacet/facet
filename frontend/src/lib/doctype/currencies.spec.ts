// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { fallbackCurrencyOptions, loadCurrencyOptions } from './currencies.js';
import type { DataDriver } from '$lib/datasource/driver.js';

/**
 * The currency option source for money filters: the `core.Currency`
 * registry (active rows, favorites first) when a driver can reach it, the
 * static ticker fallback when it cannot.
 */
function driverWith(rows: unknown): DataDriver {
	return {
		domain: () => ({
			doctype: () => ({
				list: async () => ({ data: rows, meta: { count: 0, more: false } })
			})
		})
	} as unknown as DataDriver;
}

const failingDriver: DataDriver = {
	domain: () => ({
		doctype: () => ({
			list: async () => {
				throw new Error('registry unreachable');
			}
		})
	})
} as unknown as DataDriver;

describe('currencies', () => {
	it('maps registry rows to ticker options with display-name labels', async () => {
		const driver = driverWith([
			{
				meta: { id: 'core.Currency.eur', display_name: 'Euro (EUR)' },
				data: { ticker: 'EUR', favorite: false }
			},
			{
				meta: { id: 'core.Currency.usd', display_name: 'US Dollar (USD)' },
				data: { ticker: 'USD', favorite: true }
			}
		]);
		const opts = await loadCurrencyOptions(driver);
		expect(opts).toEqual([
			{ value: 'USD', label: 'US Dollar (USD)' },
			{ value: 'EUR', label: 'Euro (EUR)' }
		]);
	});

	it('sorts favorites before the rest, then by label', async () => {
		const driver = driverWith([
			{ meta: { id: 'z', display_name: null }, data: { ticker: 'ZZZ', favorite: false } },
			{ meta: { id: 'a', display_name: null }, data: { ticker: 'AAA', favorite: true } },
			{ meta: { id: 'm', display_name: null }, data: { ticker: 'MMM', favorite: false } }
		]);
		const opts = await loadCurrencyOptions(driver);
		expect(opts.map((o) => o.value)).toEqual(['AAA', 'MMM', 'ZZZ']);
	});

	it('falls back to the static list when the registry read fails', async () => {
		const opts = await loadCurrencyOptions(failingDriver);
		expect(opts).toEqual(fallbackCurrencyOptions());
		expect(opts.length).toBeGreaterThan(0);
	});

	it('falls back when no driver is available', async () => {
		const opts = await loadCurrencyOptions(undefined);
		expect(opts).toEqual(fallbackCurrencyOptions());
	});

	it('falls back when the registry comes back empty', async () => {
		const opts = await loadCurrencyOptions(driverWith([]));
		expect(opts).toEqual(fallbackCurrencyOptions());
	});
});
