// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it } from 'vitest';
import { formatLinkValidity, pickValidityUnit } from './link-validity';

describe('pickValidityUnit', () => {
	it('states days when the TTL is a whole day multiple', () => {
		expect(pickValidityUnit(86_400)).toEqual({ count: 1, unit: 'day' });
		expect(pickValidityUnit(172_800)).toEqual({ count: 2, unit: 'day' });
	});

	it('states hours when the TTL is a whole hour multiple below a day', () => {
		expect(pickValidityUnit(3_600)).toEqual({ count: 1, unit: 'hour' });
		expect(pickValidityUnit(7_200)).toEqual({ count: 2, unit: 'hour' });
	});

	it('states minutes when the TTL is a whole minute multiple below an hour', () => {
		expect(pickValidityUnit(1_800)).toEqual({ count: 30, unit: 'minute' });
		expect(pickValidityUnit(5_400)).toEqual({ count: 90, unit: 'minute' });
		expect(pickValidityUnit(60)).toEqual({ count: 1, unit: 'minute' });
	});

	it('floors a non-minute multiple to whole minutes so the copy never overstates', () => {
		expect(pickValidityUnit(3_661)).toEqual({ count: 61, unit: 'minute' });
	});

	it('states seconds below one minute', () => {
		expect(pickValidityUnit(59)).toEqual({ count: 59, unit: 'second' });
		expect(pickValidityUnit(1)).toEqual({ count: 1, unit: 'second' });
	});

	it('clamps negative and fractional inputs', () => {
		expect(pickValidityUnit(-5)).toEqual({ count: 0, unit: 'second' });
		expect(pickValidityUnit(90.7)).toEqual({ count: 1, unit: 'minute' });
	});
});

describe('formatLinkValidity', () => {
	it('renders the singular phrase at count 1', () => {
		expect(formatLinkValidity(3_600)).toBe('1 hour');
		expect(formatLinkValidity(60)).toBe('1 minute');
	});

	it('renders the plural phrase otherwise', () => {
		expect(formatLinkValidity(1_800)).toBe('30 minutes');
		expect(formatLinkValidity(86_400)).toBe('1 day');
	});
});
