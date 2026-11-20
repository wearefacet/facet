// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { allTimezones } from './timezones.js';

// ── allTimezones ──────────────────────────────────────────────────────

describe('allTimezones', () => {
	it('always contains UTC — the server default zone', () => {
		expect(allTimezones()).toContain('UTC');
	});

	it('contains UTC exactly once', () => {
		const zones = allTimezones();
		expect(zones.filter((zone) => zone === 'UTC')).toHaveLength(1);
	});

	it('keeps every zone the runtime supports, adding only UTC', () => {
		const supported = Intl.supportedValuesOf('timeZone');
		const zones = allTimezones();
		for (const zone of supported) expect(zones).toContain(zone);
		const expected = supported.includes('UTC') ? supported.length : supported.length + 1;
		expect(zones).toHaveLength(expected);
	});

	it('falls back to a list that contains UTC when supportedValuesOf is missing', () => {
		const intl = Intl as unknown as {
			supportedValuesOf?: (key: string) => string[];
		};
		const original = intl.supportedValuesOf;
		delete intl.supportedValuesOf;
		try {
			expect(allTimezones()).toContain('UTC');
		} finally {
			intl.supportedValuesOf = original;
		}
	});
});
