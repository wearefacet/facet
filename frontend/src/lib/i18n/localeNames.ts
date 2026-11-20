// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * Locale-aware month and weekday names for the calendar surfaces.
 *
 * Month and weekday names are data, not messages (see `doc/frontend/workflow.md`
 * → Internationalization → what gets keys): they come from the runtime's
 * `Intl` database, localized with the active Paraglide locale, so every
 * calendar surface renders the same names without per-locale dictionaries.
 */

import { getLocale } from '$lib/paraglide/runtime';

interface Day {
	y: number;
	m: number;
	d: number;
}

const cache = new Map<string, string[]>();

function cachedNames(key: string, build: () => string[]): string[] {
	let names = cache.get(key);
	if (!names) {
		names = build();
		cache.set(key, names);
	}
	return names;
}

/** Gregorian month name, 1-based (`1` = January). `wide` gives the full name, default is the abbreviated form. */
export function monthName(month: number, wide = false): string {
	const locale = getLocale();
	return cachedNames(`m:${locale}:${wide}`, () => {
		const fmt = new Intl.DateTimeFormat(locale, {
			month: wide ? 'long' : 'short',
			timeZone: 'UTC'
		});
		return Array.from({ length: 12 }, (_, i) => fmt.format(Date.UTC(2026, i, 15)));
	})[month - 1];
}

/**
 * Short weekday labels ordered by the week start (`'monday'` | `'sunday'`),
 * e.g. `['Mon', …, 'Sun']` or `['Sun', …, 'Sat']`.
 */
export function localizedWeekdayLabels(weekStart: 'monday' | 'sunday'): string[] {
	const locale = getLocale();
	return cachedNames(`w:${locale}:${weekStart}`, () => {
		const fmt = new Intl.DateTimeFormat(locale, { weekday: 'short', timeZone: 'UTC' });
		// 2026-01-04 is a Sunday; index 0..6 = Sunday..Saturday.
		const sundayFirst = Array.from({ length: 7 }, (_, i) => fmt.format(Date.UTC(2026, 0, 4 + i)));
		return weekStart === 'monday' ? [...sundayFirst.slice(1), sundayFirst[0]] : sundayFirst;
	});
}

/** Short weekday name of a date, locale-aware (e.g. `"Wed"` / `"mer."`). */
export function weekdayShort(day: Day): string {
	const locale = getLocale();
	return new Intl.DateTimeFormat(locale, { weekday: 'short', timeZone: 'UTC' }).format(
		Date.UTC(day.y, day.m - 1, day.d)
	);
}

/** Long date for screen readers, locale-aware (e.g. `"January 5, 2026"` / `"5 janvier 2026"`). */
export function longDate(day: Day): string {
	const locale = getLocale();
	return new Intl.DateTimeFormat(locale, {
		dateStyle: 'long',
		timeZone: 'UTC'
	}).format(Date.UTC(day.y, day.m - 1, day.d));
}
