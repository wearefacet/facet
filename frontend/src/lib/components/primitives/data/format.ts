// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Pure money formatting, shared by the money display and input surfaces.
 *
 * The currency row (ticker, symbol, digits, grouping) comes from the currency
 * store (`currencyStore.svelte.ts`, fed by `core.Currency` documents); this
 * module owns only the formatting rules:
 *
 * - `digits` — sub-unit precision: `0` whole units, `2` cents, `3` millis.
 * - `grouping` — `standard` groups thousands (`en-US`), `lakhs` groups the
 *   Indian way `12,34,567` (`en-IN`).
 * - Symbol composition prefixes the formatted amount with the display label
 *   (the row's symbol, or the bare ticker when the row carries none — the
 *   display-fallback rule from `core.Currency`'s behaviour contract).
 */

/** Grouping styles a currency row may declare. */
export type MoneyGrouping = 'standard' | 'lakhs';

export interface MoneyFormatOptions {
	/** Sub-unit digits. Non-integer / negative values fall back to `2`. */
	digits?: number;
	/** Digit-grouping style. Defaults to `standard`. */
	grouping?: MoneyGrouping;
}

/**
 * Formats a numeric amount as a decimal display string.
 *
 * `standard` → `en-US` grouping (`1,234,567.89`); `lakhs` → `en-IN`
 * (`12,34,567.89`). The amount is always rendered with exactly `digits`
 * fractional places — money values round-half for display only; the stored
 * string value is untouched.
 */
export function formatMoneyAmount(value: number, options: MoneyFormatOptions = {}): string {
	const rawDigits = options.digits ?? 2;
	const digits = Number.isInteger(rawDigits) && rawDigits >= 0 ? rawDigits : 2;
	const locale = options.grouping === 'lakhs' ? 'en-IN' : 'en-US';
	return new Intl.NumberFormat(locale, {
		style: 'decimal',
		minimumFractionDigits: digits,
		maximumFractionDigits: digits
	}).format(value);
}

/**
 * Composes the display text from a symbol/label and a formatted amount:
 * `€ 1,234.50`. An empty label (a row with no symbol) yields the bare amount.
 */
export function composeMoneyText(label: string, formatted: string): string {
	return label === '' ? formatted : `${label} ${formatted}`;
}
