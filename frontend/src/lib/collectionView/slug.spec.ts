// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { collectionViewSlug, collectionViewIdSlug, collectionViewDeepLinkSlugs } from './slug.js';

describe('collectionViewSlug', () => {
	it('lowercases and folds spaces to underscores', () => {
		expect(collectionViewSlug('All Records')).toBe('all_records');
		expect(collectionViewSlug('By Probability')).toBe('by_probability');
		expect(collectionViewSlug('Open')).toBe('open');
	});

	it('collapses runs of separators and trims the edges', () => {
		expect(collectionViewSlug('  My   --  View!  ')).toBe('my_view');
		expect(collectionViewSlug('Wön & Only')).toBe('w_n_only');
	});

	it('returns an empty string when nothing alphanumeric survives', () => {
		expect(collectionViewSlug('')).toBe('');
		expect(collectionViewSlug(' --- ')).toBe('');
	});
});

describe('collectionViewIdSlug', () => {
	it('reads the slug from a convention-following id', () => {
		expect(collectionViewIdSlug('crm.Deal.collection_view.open')).toBe('open');
		expect(collectionViewIdSlug('crm.Deal.collection_view.by_value')).toBe('by_value');
	});

	it('returns null for ids that do not follow the convention', () => {
		expect(collectionViewIdSlug('01J5X2ABC')).toBeNull();
		expect(collectionViewIdSlug('crm.Deal')).toBeNull();
		expect(collectionViewIdSlug('crm.Deal.collection_view.')).toBeNull();
	});
});

describe('collectionViewDeepLinkSlugs', () => {
	it('prefers the id slug and appends the name slug', () => {
		expect(collectionViewDeepLinkSlugs('crm.Deal.collection_view.all', 'All Deals')).toEqual([
			'all',
			'all_deals'
		]);
	});

	it('falls back to the name slug for ULID ids', () => {
		expect(collectionViewDeepLinkSlugs('01J5X2ABC', 'Open Deals')).toEqual(['open_deals']);
	});

	it('deduplicates when both derivations agree', () => {
		expect(collectionViewDeepLinkSlugs('crm.Deal.collection_view.open', 'Open')).toEqual(['open']);
	});

	it('returns an empty list for a ULID id and an empty name', () => {
		expect(collectionViewDeepLinkSlugs('01J5X2ABC', '')).toEqual([]);
	});
});
