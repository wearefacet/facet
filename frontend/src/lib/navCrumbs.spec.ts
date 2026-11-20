// SPDX-License-Identifier: BUSL-1.1
// Copyright (c) 2026 Amplitude Solutions Ltd

import { describe, it, expect } from 'vitest';
import * as m from '$lib/paraglide/messages';
import { buildCrumbs, documentRefOf, resolveActiveDoctype, builderStatusLabel } from './navCrumbs';
import type { NavDomain } from './navTypes';

/**
 * Unit tests for the pure URL → navigation-state helpers extracted from the
 * root layout. The `labelFor` stub stands in for `getDomainLabel`; the
 * `docLabelFor` stub stands in for the layout's document label cache (the
 * show page's own rule: `meta.display_name ?? id`). The nav model fixtures
 * use the same shape `buildNavModel` returns.
 */

function navDomain(id: string, label: string, doctypes: string[] = []): NavDomain {
	return {
		id,
		label,
		color: '#000000',
		doctypes: doctypes.map((dt) => ({
			qualified: `${id}.${dt}`,
			label: dt,
			color: '#000000',
			icon: null,
			pinned: false
		})),
		updatedAt: undefined
	};
}

const DOMAINS = [
	navDomain('crm', 'CRM', ['Company', 'Contact']),
	navDomain('_abc', 'Supplier (draft)', ['Widget'])
];

/** The layout's document label cache: id → resolved display label. */
const DOC_LABELS: Record<string, string> = { '01JX': 'Acme Corp' };

const labelDomain = (id: string) => DOMAINS.find((d) => d.id === id)?.label ?? id;
const labelDocument = (id: string) => DOC_LABELS[id] ?? id;

const live = {
	isBuilderRoute: false,
	labelFor: labelDomain,
	docLabelFor: labelDocument
};
const builder = { isBuilderRoute: true, labelFor: labelDomain };
/** The old option shape: no document label source wired. */
const liveNoDocLabels = { isBuilderRoute: false, labelFor: labelDomain };

describe('buildCrumbs', () => {
	it('renders the dashboard crumb on /', () => {
		expect(buildCrumbs('/', live)).toEqual([{ label: m.nav_dashboard() }]);
	});

	it('resolves the domain segment through labelFor on live routes', () => {
		const crumbs = buildCrumbs('/crm/Company', live);
		expect(crumbs).toEqual([
			{ label: 'CRM', href: '/crm' },
			{ label: 'Company', href: undefined }
		]);
	});

	it('keeps intermediate links and drops the href on the last segment', () => {
		const crumbs = buildCrumbs('/crm/Company/01JX/show', live);
		expect(crumbs).toEqual([
			{ label: 'CRM', href: '/crm', title: undefined },
			{ label: 'Company', href: '/crm/Company', title: undefined },
			// The id segment resolves through the label cache; the raw id rides
			// the title attribute for copyability.
			{ label: 'Acme Corp', href: '/crm/Company/01JX', title: '01JX' },
			{ label: 'Show', href: undefined, title: undefined }
		]);
	});

	it('falls back to the raw id when the document label cache misses', () => {
		const crumbs = buildCrumbs('/crm/Company/UNKNOWN/show', live);
		expect(crumbs[2]).toEqual({ label: 'UNKNOWN', href: '/crm/Company/UNKNOWN', title: 'UNKNOWN' });
	});

	it('keeps the create-form segment capitalized instead of resolving it', () => {
		// `/{domain}/{doctype}/new` is the create form — a static sibling
		// route, so `new` is a literal, not a document id. The `core` domain
		// is not in the nav model, so segment 0 keeps the raw id (the labelFor
		// fallback the domain test pins).
		const crumbs = buildCrumbs('/core/Currency/new', live);
		expect(crumbs).toEqual([
			{ label: 'core', href: '/core', title: undefined },
			{ label: 'Currency', href: '/core/Currency', title: undefined },
			{ label: 'New', href: undefined, title: undefined }
		]);
	});

	it('renders the id segment capitalized when docLabelFor is omitted', () => {
		const crumbs = buildCrumbs('/crm/Company/01JX/show', liveNoDocLabels);
		expect(crumbs[2]).toEqual({ label: '01JX', href: '/crm/Company/01JX', title: undefined });
	});

	it('resolves the draft domain segment (index 1) on builder routes', () => {
		const crumbs = buildCrumbs('/Builder/_abc/overview', builder);
		expect(crumbs).toEqual([
			{ label: 'Builder', href: '/Builder' },
			{ label: 'Supplier (draft)', href: '/Builder/_abc' },
			{ label: 'Overview', href: undefined }
		]);
	});

	it('does not resolve segment 0 as a domain on builder routes', () => {
		// `/Builder` alone: one segment, capitalized, no label resolution.
		expect(buildCrumbs('/Builder', builder)).toEqual([{ label: 'Builder', href: undefined }]);
	});

	it('falls back to the raw id when labelFor misses', () => {
		// getDomainLabel returns the id itself for an unknown domain; the
		// capitalized default only applies to segments that skip labelFor.
		const crumbs = buildCrumbs('/unknown/Thing', live);
		expect(crumbs[0]).toEqual({ label: 'unknown', href: '/unknown', title: undefined });
	});
});

describe('documentRefOf', () => {
	it('splits a show route into its decoded parts', () => {
		expect(documentRefOf('/crm/Company/01JX', false)).toEqual({
			domain: 'crm',
			doctype: 'Company',
			id: '01JX'
		});
	});

	it('matches the edit and history siblings', () => {
		expect(documentRefOf('/crm/Company/01JX/edit', false)?.id).toBe('01JX');
		expect(documentRefOf('/crm/Company/01JX/history', false)?.id).toBe('01JX');
	});

	it('decodes percent-encoded segments', () => {
		expect(documentRefOf('/hr/Leave%20Request/01JX/history', false)).toEqual({
			domain: 'hr',
			doctype: 'Leave Request',
			id: '01JX'
		});
	});

	it('returns null off the document routes', () => {
		expect(documentRefOf('/', false)).toBeNull();
		expect(documentRefOf('/crm', false)).toBeNull();
		expect(documentRefOf('/crm/Company', false)).toBeNull();
	});

	it('returns null on the create form (the literal new segment)', () => {
		expect(documentRefOf('/core/Currency/new', false)).toBeNull();
	});

	it('returns null on builder routes', () => {
		expect(documentRefOf('/crm/Company/01JX/show', true)).toBeNull();
	});

	it('returns null on a broken percent-escape', () => {
		expect(documentRefOf('/crm/%ZZ/01JX', false)).toBeNull();
	});
});

describe('resolveActiveDoctype', () => {
	it('resolves a live doctype from /{domain}/{doctype}', () => {
		expect(resolveActiveDoctype('/crm/Company', DOMAINS, false)).toBe('crm.Company');
	});

	it('keeps the doctype when an id segment follows', () => {
		expect(resolveActiveDoctype('/crm/Company/01JX', DOMAINS, false)).toBe('crm.Company');
	});

	it('resolves a builder doctype from /Builder/{draft}/{doctype}[/tab]', () => {
		expect(resolveActiveDoctype('/Builder/_abc/Widget/logic', DOMAINS, true)).toBe('_abc.Widget');
	});

	it('resolves a composition child nested under its parent', () => {
		// The nav model nests member_of children; the URL segment matches a
		// child label inside the parent's subtree.
		const domains = [
			{
				...navDomain('crm', 'CRM', []),
				doctypes: [
					{
						qualified: 'crm.Company',
						label: 'Company',
						color: '#000000',
						icon: null,
						pinned: false,
						children: [
							{
								qualified: 'crm.Membership',
								label: 'Membership',
								color: '#000000',
								icon: null,
								pinned: false
							}
						]
					}
				]
			},
			{
				...navDomain('_abc', 'Supplier (draft)', []),
				doctypes: [
					{
						qualified: '_abc.Company',
						label: 'Company',
						color: '#000000',
						icon: null,
						pinned: false,
						children: [
							{
								qualified: '_abc.Membership',
								label: 'Membership',
								color: '#000000',
								icon: null,
								pinned: false
							}
						]
					}
				]
			}
		];
		expect(resolveActiveDoctype('/crm/Membership', domains, false)).toBe('crm.Membership');
		expect(resolveActiveDoctype('/Builder/_abc/Membership/fields', domains, true)).toBe(
			'_abc.Membership'
		);
	});

	it('decodes a percent-encoded doctype segment', () => {
		const domains = [navDomain('hr', 'HR', ['Leave Request'])];
		expect(resolveActiveDoctype('/hr/Leave%20Request', domains, false)).toBe('hr.Leave Request');
	});

	it('returns undefined below two segments', () => {
		expect(resolveActiveDoctype('/', DOMAINS, false)).toBeUndefined();
		expect(resolveActiveDoctype('/crm', DOMAINS, false)).toBeUndefined();
	});

	it('returns undefined on the builder landing (no doctype segment)', () => {
		expect(resolveActiveDoctype('/Builder', DOMAINS, true)).toBeUndefined();
		expect(resolveActiveDoctype('/Builder/_abc', DOMAINS, true)).toBeUndefined();
	});

	it('returns undefined when the doctype is not in the nav model', () => {
		expect(resolveActiveDoctype('/crm/Missing', DOMAINS, false)).toBeUndefined();
		expect(resolveActiveDoctype('/Builder/_abc/Missing', DOMAINS, true)).toBeUndefined();
	});
});

describe('builderStatusLabel', () => {
	it('returns undefined off the builder routes', () => {
		expect(builderStatusLabel(false, 'crm', DOMAINS)).toBeUndefined();
	});

	it('reports the active draft label', () => {
		expect(builderStatusLabel(true, '_abc', DOMAINS)).toBe(
			m.builder_status_editing({ name: 'Supplier (draft)' })
		);
	});

	it('falls back to the no-draft message when the id is unknown', () => {
		expect(builderStatusLabel(true, '_missing', DOMAINS)).toBe(m.builder_status_no_draft());
	});
});
