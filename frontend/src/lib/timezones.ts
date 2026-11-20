// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

/**
 * The IANA zone list the timezone selects render — one builder for the
 * personal settings page and the platform SystemSettingsForm, so both
 * surfaces offer the same zones.
 *
 * `allTimezones()` returns every zone the runtime supports
 * (`Intl.supportedValuesOf('timeZone')`), falling back to a stable subset
 * when the API is missing. The list always contains `UTC` — the server
 * default zone — because V8 omits it from the supported list, and a picker
 * bound to the merged default must find an option for it.
 * `zoneOffsetLabel(zone)` renders the current GMT offset ("+2") for a zone;
 * it degrades to the zone name when the runtime cannot format it.
 */

/** Stable fallback when `Intl.supportedValuesOf` is unavailable (SSR, old runtimes). */
const FALLBACK_ZONES = [
	'UTC',
	'Europe/London',
	'Europe/Paris',
	'Europe/Berlin',
	'Europe/Madrid',
	'Europe/Rome',
	'Europe/Amsterdam',
	'Europe/Warsaw',
	'Europe/Brussels',
	'Europe/Vienna',
	'Europe/Zurich',
	'Europe/Stockholm',
	'Europe/Oslo',
	'Europe/Copenhagen',
	'Europe/Helsinki',
	'Europe/Lisbon',
	'Europe/Dublin',
	'Europe/Athens',
	'Europe/Istanbul',
	'Europe/Moscow',
	'America/New_York',
	'America/Chicago',
	'America/Denver',
	'America/Los_Angeles',
	'America/Toronto',
	'America/Vancouver',
	'America/Mexico_City',
	'America/Sao_Paulo',
	'America/Buenos_Aires',
	'America/Bogota',
	'Africa/Cairo',
	'Africa/Lagos',
	'Africa/Nairobi',
	'Africa/Johannesburg',
	'Asia/Dubai',
	'Asia/Riyadh',
	'Asia/Kolkata',
	'Asia/Bangkok',
	'Asia/Singapore',
	'Asia/Hong_Kong',
	'Asia/Shanghai',
	'Asia/Tokyo',
	'Asia/Seoul',
	'Australia/Sydney',
	'Australia/Melbourne',
	'Pacific/Auckland'
];

/** All IANA zones the runtime supports, plus `UTC` (always present, first). */
export function allTimezones(): string[] {
	if (typeof Intl !== 'undefined' && typeof Intl.supportedValuesOf === 'function') {
		const zones = Intl.supportedValuesOf('timeZone') as string[];
		if (zones && zones.length > 0) {
			// V8 leaves `UTC` out of the supported list, but the server default
			// is `UTC`: keep an entry so every picker can bind the merged value.
			return zones.includes('UTC') ? zones : ['UTC', ...zones];
		}
	}
	return FALLBACK_ZONES;
}

/** The current GMT offset label for an IANA zone (e.g. `"+2"`); the zone name on failure. */
export function zoneOffsetLabel(zone: string): string {
	try {
		const now = Date.now();
		const formatter = new Intl.DateTimeFormat('en-US', {
			timeZone: zone,
			timeZoneName: 'shortOffset',
			day: '2-digit'
		});
		const parts = formatter.formatToParts(now);
		const tzPart = parts.find((p) => p.type === 'timeZoneName');
		return tzPart ? tzPart.value.replace('GMT', '') : zone;
	} catch {
		return zone;
	}
}
