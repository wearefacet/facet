// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { resolveColumnLabel } from './columnLabel.js';
import type { DoctypeDef } from './types.js';

const def: DoctypeDef = {
	doctype: 'Deal',
	domain: 'crm',
	fields: [
		{ key: 'title', type: 'string', title: 'Deal Title' },
		{ key: 'lost_reason', type: 'string' },
		{ key: 'probability', type: 'integer', title: 'Probability' }
	],
	children: [],
	actions: []
};

describe('resolveColumnLabel', () => {
	it('keeps a saved label verbatim', () => {
		expect(resolveColumnLabel(def, 'title', 'Deal')).toBe('Deal');
	});

	it('falls back to the field title when the label is absent', () => {
		expect(resolveColumnLabel(def, 'title', undefined)).toBe('Deal Title');
	});

	it('humanizes a key whose field declares no title', () => {
		// The raw key would print as `LOST_REASON` under the table's uppercase.
		expect(resolveColumnLabel(def, 'lost_reason', undefined)).toBe('Lost Reason');
	});

	it('humanizes an unknown key (a removed field)', () => {
		expect(resolveColumnLabel(def, 'f_string', undefined)).toBe('F String');
	});
});
