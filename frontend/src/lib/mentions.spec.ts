// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it } from 'vitest';
import { ACCOUNT_URN_PREFIX, accountUrn, mentionMarkdown, parseAccountUrn } from './mentions.js';

describe('accountUrn / parseAccountUrn round-trip', () => {
	const ID = '01J5X2QK7M8N9P0R1S2T3V4W5X';

	it('round-trips a bare account id through the colon form', () => {
		const urn = accountUrn(ID);
		expect(urn).toBe(`urn:facet:iam:Account:${ID}`);
		expect(parseAccountUrn(urn)).toBe(ID);
	});

	it('exposes the canonical colon prefix', () => {
		expect(ACCOUNT_URN_PREFIX).toBe('urn:facet:iam:Account:');
	});

	it('rejects non-URN hrefs', () => {
		expect(parseAccountUrn(null)).toBeNull();
		expect(parseAccountUrn('')).toBeNull();
		expect(parseAccountUrn('https://example.com')).toBeNull();
		expect(parseAccountUrn('urn:facet:crm:Company:01J5X2')).toBeNull();
		expect(parseAccountUrn('urn:facet:artifact:01J5X2')).toBeNull();
		expect(parseAccountUrn(`iam.Account.${ID}`)).toBeNull();
	});

	it('rejects state-pinned URNs — they render as plain links, not chips', () => {
		expect(parseAccountUrn(`${accountUrn(ID)}?state=01ABC`)).toBeNull();
	});

	it('rejects a prefix-only href with no id', () => {
		expect(parseAccountUrn(ACCOUNT_URN_PREFIX)).toBeNull();
	});
});

describe('mentionMarkdown', () => {
	it('keeps the trigger glyph in the label', () => {
		expect(mentionMarkdown('01AB', 'Jane Doe')).toBe('[@Jane Doe](urn:facet:iam:Account:01AB)');
	});
});
