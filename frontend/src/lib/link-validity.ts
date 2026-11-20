// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import * as m from '$lib/paraglide/messages';

const SECONDS_PER_MINUTE = 60;
const SECONDS_PER_HOUR = 60 * SECONDS_PER_MINUTE;
const SECONDS_PER_DAY = 24 * SECONDS_PER_HOUR;

/** Units the validity copy can state, smallest to largest. */
export type ValidityUnit = 'second' | 'minute' | 'hour' | 'day';

/**
 * Pick the count/unit pair the link-validity copy states: the largest unit
 * that divides the TTL exactly (day → hour → minute), so the 24 h default
 * renders as "1 day" and a 30 min TTL as "30 minutes". A non-minute
 * multiple floors to whole minutes — the copy must never overstate the
 * window. Sub-minute TTLs state seconds.
 */
export function pickValidityUnit(seconds: number): { count: number; unit: ValidityUnit } {
	const total = Math.max(0, Math.floor(seconds));
	if (total >= SECONDS_PER_DAY && total % SECONDS_PER_DAY === 0) {
		return { count: total / SECONDS_PER_DAY, unit: 'day' };
	}
	if (total >= SECONDS_PER_HOUR && total % SECONDS_PER_HOUR === 0) {
		return { count: total / SECONDS_PER_HOUR, unit: 'hour' };
	}
	if (total >= SECONDS_PER_MINUTE) {
		return { count: Math.floor(total / SECONDS_PER_MINUTE), unit: 'minute' };
	}
	return { count: total, unit: 'second' };
}

type ValidityMessage = (inputs: { count: number }) => string;

const UNIT_MESSAGES: Record<ValidityUnit, { one: ValidityMessage; other: ValidityMessage }> = {
	second: { one: m.common_validity_second, other: m.common_validity_seconds },
	minute: { one: m.common_validity_minute, other: m.common_validity_minutes },
	hour: { one: m.common_validity_hour, other: m.common_validity_hours },
	day: { one: m.common_validity_day, other: m.common_validity_days }
};

/**
 * Format a seconds count as a localized validity phrase — "1 day" (en) /
 * "1 jour" (fr). Only en and fr ship, and both pluralize the same way
 * (singular at count 1), so the singular/plural pick is a comparison.
 */
export function formatLinkValidity(seconds: number): string {
	const { count, unit } = pickValidityUnit(seconds);
	const entry = UNIT_MESSAGES[unit];
	return (count === 1 ? entry.one : entry.other)({ count });
}
