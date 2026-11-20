// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it } from 'vitest';
import {
	docRefMarkdown,
	docUrn,
	doctypeMatches,
	parseDocUrn,
	parseShowUrl,
	showRoute,
	type DocTypeOption
} from './docrefs.js';

const ULID = '01J5X2QK7M8N9P0R1S2T3V4W5X';

describe('docUrn / parseDocUrn round-trip', () => {
	it('round-trips a document through the colon form', () => {
		const urn = docUrn('crm', 'Company', ULID);
		expect(urn).toBe(`urn:facet:crm:Company:${ULID}`);
		expect(parseDocUrn(urn)).toEqual({ domain: 'crm', doctype: 'Company', id: ULID });
	});

	it('rejects the artifact scheme — four segments', () => {
		expect(parseDocUrn('urn:facet:artifact:01J5X2')).toBeNull();
	});

	it('rejects other schemes and the dotted reference form', () => {
		expect(parseDocUrn('https://example.com')).toBeNull();
		expect(parseDocUrn(`crm.Company.${ULID}`)).toBeNull();
		expect(parseDocUrn('facet://crm/Company/01')).toBeNull();
	});

	it('rejects state-pinned URNs — they render as plain links', () => {
		expect(parseDocUrn(`${docUrn('crm', 'Company', ULID)}?state=01ABC`)).toBeNull();
	});

	it('rejects malformed segments', () => {
		expect(parseDocUrn('urn:facet::Company:01')).toBeNull();
		expect(parseDocUrn('urn:facet:crm::01')).toBeNull();
		expect(parseDocUrn('urn:facet:crm:Company:')).toBeNull();
		expect(parseDocUrn('urn:facet:CRM:Company:01')).toBeNull();
		expect(parseDocUrn('urn:facet:crm:company:01')).toBeNull();
		expect(parseDocUrn('urn:facet:crm:Company:bad id')).toBeNull();
	});
});

describe('docRefMarkdown / showRoute', () => {
	it('builds a plain-label markdown link', () => {
		expect(docRefMarkdown('crm', 'Company', ULID, 'Acme Corp')).toBe(
			`[Acme Corp](urn:facet:crm:Company:${ULID})`
		);
	});

	it('builds the live show route — the shape paste-to-chip detects', () => {
		expect(showRoute('crm', 'Company', ULID)).toBe(`/crm/Company/${ULID}`);
	});
});

describe('parseShowUrl', () => {
	it('parses a relative show URL', () => {
		expect(parseShowUrl(`/crm/Company/${ULID}`)).toEqual({
			domain: 'crm',
			doctype: 'Company',
			id: ULID
		});
	});

	it('parses an absolute URL on any origin', () => {
		expect(parseShowUrl(`https://app.example.com/hr/Employee/${ULID}`)).toEqual({
			domain: 'hr',
			doctype: 'Employee',
			id: ULID
		});
	});

	it('ignores query strings and hash', () => {
		expect(parseShowUrl(`/crm/Company/${ULID}?tab=history`)).toEqual({
			domain: 'crm',
			doctype: 'Company',
			id: ULID
		});
	});

	it('rejects non-show paths', () => {
		expect(parseShowUrl('/crm/Company')).toBeNull();
		expect(parseShowUrl(`/Api/crm/Company/${ULID}`)).toBeNull();
		expect(parseShowUrl(`/crm/company/${ULID}`)).toBeNull();
		expect(parseShowUrl('/crm/Company/with spaces')).toBeNull();
		expect(parseShowUrl('not a url')).toBeNull();
		expect(parseShowUrl('')).toBeNull();
	});
});

describe('doctypeMatches — the narrowing match', () => {
	const option: DocTypeOption = {
		target: 'crm.Company',
		domain: 'crm',
		name: 'Company',
		pluralLabel: 'companies'
	};

	it('matches case-insensitively over the human label', () => {
		expect(doctypeMatches(option, 'Compan')).toBe(true);
		expect(doctypeMatches(option, 'companies')).toBe(true);
	});

	it('matches over the technical name and the qualified id', () => {
		expect(doctypeMatches(option, 'company')).toBe(true);
		expect(doctypeMatches(option, 'crm.comp')).toBe(true);
	});

	it('does not match unrelated queries', () => {
		expect(doctypeMatches(option, 'contact')).toBe(false);
	});

	it('matches everything on an empty query', () => {
		expect(doctypeMatches(option, '')).toBe(true);
		expect(doctypeMatches(option, '   ')).toBe(true);
	});
});
