// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, expect, it } from 'vitest';
import { renderTemplate } from './templating.js';

describe('renderTemplate', () => {
	it('substitutes {{ field }} placeholders', () => {
		expect(renderTemplate('{{ name }} {{ subject }}', { name: 'Swap', subject: 'Filter' })).toBe(
			'Swap Filter'
		);
	});

	it('tolerates whitespace inside the braces', () => {
		expect(renderTemplate('{{name}}', { name: 'Swap' })).toBe('Swap');
		expect(renderTemplate('{{  name  }}', { name: 'Swap' })).toBe('Swap');
	});

	it('walks dotted paths', () => {
		expect(renderTemplate('{{ address.postal_code }}', { address: { postal_code: '1010' } })).toBe(
			'1010'
		);
	});

	it('walks the raw tree through the content. root', () => {
		expect(renderTemplate('{{ content.address.city }}', { address: { city: 'Vienna' } })).toBe(
			'Vienna'
		);
	});

	it('renders missing fields as empty', () => {
		expect(renderTemplate('{{ name }} {{ subject }}', { name: 'Swap' })).toBe('Swap ');
		expect(renderTemplate('{{ missing }}', {})).toBe('');
	});

	it('renders a missing intermediate node as empty', () => {
		expect(renderTemplate('{{ a.b.c }}', {})).toBe('');
	});

	it('formats a money object as "<currency> <value>"', () => {
		expect(renderTemplate('{{ amount }}', { amount: { value: '100', currency: 'EUR' } })).toBe(
			'EUR 100'
		);
	});

	it('formats money nested behind a dotted path', () => {
		expect(
			renderTemplate('{{ deal.amount }}', { deal: { amount: { value: '9.5', currency: 'USD' } } })
		).toBe('USD 9.5');
	});

	it('renders a plain object as empty', () => {
		expect(renderTemplate('{{ address }}', { address: { city: 'Vienna' } })).toBe('');
	});

	it('joins array elements with ", "', () => {
		expect(renderTemplate('{{ tags }}', { tags: ['a', 'b'] })).toBe('a, b');
	});

	it('renders numbers and booleans', () => {
		expect(renderTemplate('{{ n }} {{ ok }}', { n: 42, ok: true })).toBe('42 true');
	});

	it('keeps plain text verbatim', () => {
		expect(renderTemplate('Deal: {{ name }}!', { name: 'Swap' })).toBe('Deal: Swap!');
	});

	it('renders unsupported Jinja verbatim', () => {
		// Filters and statement blocks match no placeholder — they surface in
		// the output instead of failing silently.
		expect(renderTemplate('{{ name | upper }}', { name: 'Swap' })).toBe('{{ name | upper }}');
		expect(renderTemplate('{% if name %}x{% endif %}', { name: 'Swap' })).toBe(
			'{% if name %}x{% endif %}'
		);
	});

	it('renders a `{#` comment opener verbatim', () => {
		expect(renderTemplate('a {# note #} b', {})).toBe('a {# note #} b');
	});
});
