// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Shared money-currency contracts for the money display and input surfaces.
 *
 * The live currency set is *data*, not code: `core.Currency` documents feed
 * the currency store (`currencyStore.svelte.ts`), which the Money display and
 * the MoneyInput picker read. This module keeps only the pieces that must
 * exist even when the store is empty or unreachable:
 *
 * - `DEFAULT_CURRENCY` — the last-resort fallback ticker ('EUR');
 * - `CurrencyDef` — the display contract every currency row satisfies;
 * - `canonicalTicker` — narrows an arbitrary value to a usable ticker string.
 */

export interface CurrencyDef {
	/** ISO-4217-style ticker, uppercase, stored verbatim. */
	ticker: string;
	/** Decimal digits for the currency's smallest unit (0 whole units … 4). */
	digits: number;
}

/** Default currency when neither the value nor the field definition carries one. */
export const DEFAULT_CURRENCY = 'EUR';

/**
 * Narrows an arbitrary value to a usable ticker string. A non-string or
 * empty value falls back to {@link DEFAULT_CURRENCY}; anything else stays
 * verbatim (money tickers are submitted exactly as stored — the backend's
 * `ticker` pattern enforces the shape there).
 */
export function canonicalTicker(value: unknown): string {
	if (typeof value === 'string' && value.trim() !== '') return value;
	return DEFAULT_CURRENCY;
}
