// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import { slugifyDomainLabel } from './slugify.js';

describe('slugifyDomainLabel', () => {
	it('lowercases and dashes a simple label', () => {
		expect(slugifyDomainLabel('My Domain')).toBe('my-domain');
		expect(slugifyDomainLabel('CRM')).toBe('crm');
	});

	it('folds runs of non-alphanumeric characters into one dash', () => {
		expect(slugifyDomainLabel('  HR & Payroll! ')).toBe('hr-payroll');
		expect(slugifyDomainLabel("L'atelier — TODOs")).toBe('l-atelier-todos');
		expect(slugifyDomainLabel('my_domain')).toBe('my-domain');
	});

	it('strips accents so French labels infer clean ids', () => {
		expect(slugifyDomainLabel('Création de comptes')).toBe('creation-de-comptes');
		expect(slugifyDomainLabel('Dépôts & Garanties')).toBe('depots-garanties');
	});

	it('trims leading and trailing dashes', () => {
		expect(slugifyDomainLabel('--Orders--')).toBe('orders');
		expect(slugifyDomainLabel('?!')).toBe('');
	});

	it('keeps a leading digit — the caller surfaces the contract error', () => {
		expect(slugifyDomainLabel('3D Printing')).toBe('3d-printing');
	});

	it('maps an empty label to an empty id', () => {
		expect(slugifyDomainLabel('')).toBe('');
		expect(slugifyDomainLabel('   ')).toBe('');
	});
});
