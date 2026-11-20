// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { splitQualifiedRef, splitQualifiedDoctype } from './qualifiedRef.js';

describe('splitQualifiedRef', () => {
	it('splits a domain.Doctype.id reference', () => {
		expect(splitQualifiedRef('crm.Deal.1')).toEqual({ domain: 'crm', doctype: 'Deal', id: '1' });
	});

	it('keeps dots inside the opaque id', () => {
		expect(splitQualifiedRef('iam.Account.a.b.c')).toEqual({
			domain: 'iam',
			doctype: 'Account',
			id: 'a.b.c'
		});
	});

	it('returns null for an unqualified value', () => {
		expect(splitQualifiedRef('plain-id')).toBeNull();
	});

	it('returns null for a two-part doctype token', () => {
		expect(splitQualifiedRef('crm.Deal')).toBeNull();
	});

	it('returns null for an empty domain', () => {
		expect(splitQualifiedRef('.Deal.1')).toBeNull();
	});

	it('returns null for null, undefined and empty input', () => {
		expect(splitQualifiedRef(null)).toBeNull();
		expect(splitQualifiedRef(undefined)).toBeNull();
		expect(splitQualifiedRef('')).toBeNull();
	});
});

describe('splitQualifiedDoctype', () => {
	it('splits a domain.Doctype token', () => {
		expect(splitQualifiedDoctype('crm.Deal')).toEqual({ domain: 'crm', doctype: 'Deal' });
	});

	it('keeps dots inside the doctype segment', () => {
		expect(splitQualifiedDoctype('crm.Sub.Type')).toEqual({ domain: 'crm', doctype: 'Sub.Type' });
	});

	it('returns null for a bare doctype name', () => {
		expect(splitQualifiedDoctype('Deal')).toBeNull();
	});

	it('returns null for an empty domain', () => {
		expect(splitQualifiedDoctype('.Deal')).toBeNull();
	});

	it('returns null for null, undefined and empty input', () => {
		expect(splitQualifiedDoctype(null)).toBeNull();
		expect(splitQualifiedDoctype(undefined)).toBeNull();
		expect(splitQualifiedDoctype('')).toBeNull();
	});
});
