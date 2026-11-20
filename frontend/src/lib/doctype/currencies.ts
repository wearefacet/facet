// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Currency options for money filters (the `__currency` chip and the kanban
 * lane editor's currency control).
 *
 * The primary source is the `core.Currency` registry — one row per world
 * currency, with `active` gating picker visibility and `favorite` pinning
 * rows to the top (the same rule the money field editors use). When no
 * driver is available or the registry read fails, a small static ISO-4217
 * fallback keeps the control usable in storybook and offline surfaces.
 */

import type { DataDriver } from '$lib/datasource/driver.js';

/** One flat currency entry — what the currency pickers render. */
export interface CurrencyOption {
	value: string;
	label: string;
}

/**
 * Fallback ticker list for surfaces without a driver (or when the registry
 * read fails). Common circulating currencies only — the registry remains
 * the source of truth whenever it can be reached.
 */
const FALLBACK_TICKERS: readonly string[] = [
	'USD',
	'EUR',
	'GBP',
	'CHF',
	'JPY',
	'CNY',
	'CAD',
	'AUD',
	'NZD',
	'SEK',
	'NOK',
	'DKK',
	'PLN',
	'CZK',
	'HUF',
	'MXN',
	'BRL',
	'ZAR',
	'SGD',
	'HKD',
	'KRW',
	'INR',
	'TRY',
	'AED',
	'ILS'
];

/** Flat ticker options — the offline fallback shape. */
export function fallbackCurrencyOptions(): CurrencyOption[] {
	return FALLBACK_TICKERS.map((ticker) => ({ value: ticker, label: ticker }));
}

interface CurrencyRow {
	meta: { id: string; display_name?: string | null };
	data: { ticker?: unknown; favorite?: unknown };
}

/**
 * Loads the active currencies from the `core.Currency` registry through the
 * driver: favorites first, then by label. Falls back to the static ticker
 * list when no driver is present or the read fails — the control must stay
 * usable either way.
 */
export async function loadCurrencyOptions(
	driver: DataDriver | undefined
): Promise<CurrencyOption[]> {
	if (!driver) return fallbackCurrencyOptions();
	try {
		const res = await driver
			.domain('core')
			.doctype('Currency')
			.list({
				filters: { active__eq: 'true' },
				items: 300
			});
		const rows = res.data as unknown as CurrencyRow[];
		if (rows.length === 0) return fallbackCurrencyOptions();
		const options: CurrencyOption[] = rows.map((row) => ({
			value: String(row.data?.ticker ?? row.meta.id),
			label: row.meta.display_name || String(row.data?.ticker ?? row.meta.id)
		}));
		// Favorites first, then alphabetical — mirrors the currency picker rule.
		const isFavorite = new Set(
			rows
				.filter((row) => row.data?.favorite === true)
				.map((row) => String(row.data?.ticker ?? row.meta.id))
		);
		return options.sort((a, b) => {
			const fa = isFavorite.has(a.value) ? 0 : 1;
			const fb = isFavorite.has(b.value) ? 0 : 1;
			if (fa !== fb) return fa - fb;
			return a.label.localeCompare(b.label);
		});
	} catch {
		return fallbackCurrencyOptions();
	}
}
