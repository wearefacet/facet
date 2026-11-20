// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it } from 'vitest';
import { tagUnionOverflow } from './roleTags.js';

describe('tagUnionOverflow', () => {
	it('accepts tags inside the caller union', () => {
		expect(tagUnionOverflow(['default', 'hr'], ['default'], ['default', 'hr'])).toEqual([]);
	});

	it('accepts tags inside the committed union even when the caller lacks them', () => {
		// The role already carries the tag — narrowing or keeping it is
		// always allowed (the backend unions previous and caller tags).
		expect(tagUnionOverflow(['default', 'pay'], ['pay'], ['default'])).toEqual([]);
	});

	it('names tags outside both baselines', () => {
		expect(tagUnionOverflow(['default', 'finance'], ['default'], ['default', 'hr'])).toEqual([
			'finance'
		]);
	});

	it('allows every tag when the union holds the wildcard', () => {
		expect(tagUnionOverflow(['pay', 'anything'], [], ['*'])).toEqual([]);
		expect(tagUnionOverflow(['pay'], ['*'], ['default'])).toEqual([]);
	});

	it('defers to the backend when the caller tags are unknown', () => {
		expect(tagUnionOverflow(['finance'], [], null)).toEqual([]);
	});

	it('allows an empty next list (narrowing to nothing still passes the union)', () => {
		expect(tagUnionOverflow([], ['default'], ['default'])).toEqual([]);
	});
});
