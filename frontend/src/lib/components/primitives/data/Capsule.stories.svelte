<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, waitFor, within } from 'storybook/test';
	import Capsule from './Capsule.svelte';
	import { createMockDriver } from '$lib/datasource/mock-seed.js';

	const driver = createMockDriver();

	// Shared scratch variable for stories that verify click handler invocations.
	// Stories reset it before each run; the `play` function asserts after clicking.
	let lastRefClick: { domain: string; doctype: string; id: string } | null = null;

	const { Story } = defineMeta({
		title: 'Components/Primitives/Data/Capsule',
		component: Capsule,
		tags: ['autodocs'],
		argTypes: {
			doctype: {
				control: 'select',
				options: ['invoice', 'shipment', 'contact', 'task', 'document', 'contract']
			}
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});
</script>

<Story name="Invoice" args={{ label: 'INV-0486', doctype: 'invoice' }} />
<Story name="Shipment" args={{ label: 'SHP-3369', doctype: 'shipment' }} />
<Story name="Contact" args={{ label: 'VND-0014', doctype: 'contact' }} />
<Story name="Task" args={{ label: 'TSK-204', doctype: 'task' }} />
<Story name="Document" args={{ label: 'BOL-7741', doctype: 'document' }} />
<Story name="Contract" args={{ label: 'CT-0022', doctype: 'contract' }} />

<Story name="WithSuffix" args={{ label: 'INV-0486', doctype: 'invoice', suffix: '€ 28,900.00' }} />

<Story name="AsLink" args={{ label: 'INV-0486', doctype: 'invoice', href: '#' }} />

<!-- Reference hydration — driver + reference keyword trigger display_name fetch -->

<Story
	name="Reference"
	args={{
		driver,
		reference: 'crm.Deal.1'
	}}
	play={async ({ canvasElement }) => {
		const _canvas = within(canvasElement);
		// After hydration: shows the deal's `display_name` (title field) and
		// never the raw qualified id.
		await waitFor(() => {
			const label = canvasElement.querySelector('.capsule');
			expect(label?.textContent ?? '').toContain('Acme Corp');
			expect(label?.textContent ?? '').not.toContain('crm.Deal.1');
		});
		// No failure indicator on a successful hydrate.
		const warn = canvasElement.querySelector('[data-tooltip-trigger]');
		expect(warn).toBeNull();
	}}
/>

<Story
	name="BareIdReference"
	args={{
		driver,
		reference: 'account_recruiter_kim',
		qualifiedDoctype: 'iam.Account'
	}}
	play={async ({ canvasElement }) => {
		within(canvasElement);
		// Bare id + qualifiedDoctype hint — the capsule should hydrate the
		// referenced iam.Account and display the account's display_name.
		await waitFor(() => {
			const label = canvasElement.querySelector('.capsule');
			expect(label?.textContent ?? '').toContain('Kim Nguyen');
			expect(label?.textContent ?? '').not.toContain('account_recruiter_kim');
		});
		const warn = canvasElement.querySelector('[data-tooltip-trigger]');
		expect(warn).toBeNull();
	}}
/>

<Story
	name="ClickableReference"
	args={{
		driver,
		reference: 'crm.Deal.1',
		onreferenceclick: (e: { domain: string; doctype: string; id: string }) => {
			lastRefClick = e;
		}
	}}
	play={async ({ canvasElement }) => {
		lastRefClick = null;
		within(canvasElement);
		// Clickable reference capsule should render as a <button>, fire
		// onreferenceclick with the referenced id on click, and keep the
		// hydrated display_name after hydration completes.
		await waitFor(() => {
			const btn = canvasElement.querySelector('button.capsule');
			expect(btn).not.toBeNull();
			expect(btn?.textContent ?? '').toContain('Acme Corp');
		});
		const btn = canvasElement.querySelector('button.capsule') as HTMLButtonElement;
		btn.click();
		expect(lastRefClick).toEqual({
			domain: 'crm',
			doctype: 'Deal',
			id: 'crm.Deal.1'
		});
		lastRefClick = null;
	}}
/>

<!-- Non-reference capsule (label only) must stay non-interactive even when
     onreferenceclick is wired — no `reference` + no `parts` means no button. -->
<Story
	name="NonClickableLabel"
	args={{
		label: 'INV-0486',
		doctype: 'invoice',
		onreferenceclick: () => {}
	}}
	play={({ canvasElement }) => {
		within(canvasElement);
		const btn = canvasElement.querySelector('button.capsule');
		expect(btn).toBeNull();
		const span = canvasElement.querySelector('span.capsule');
		expect(span?.textContent ?? '').toContain('INV-0486');
	}}
/>

<Story
	name="UnresolvedReference"
	args={{
		driver,
		reference: 'crm.Deal.does-not-exist'
	}}
	play={async ({ canvasElement }) => {
		const _canvas = within(canvasElement);
		// Failure fallback: keeps the dotted qualified id…
		await waitFor(() => {
			const label = canvasElement.querySelector('.capsule');
			expect(label?.textContent ?? '').toContain('crm.Deal.does-not-exist');
		});
		// …and surfaces a (?) tooltip trigger so the user knows the fetch failed.
		await waitFor(() => {
			const warn = canvasElement.querySelector('[data-tooltip-trigger]');
			expect(warn).not.toBeNull();
		});
	}}
/>

<!-- Long display_name is truncated to 32 chars with an ellipsis, and the full
     name is exposed via the hover `title` so AT and tooltips can still read it. -->
<Story
	name="TruncatedLabel"
	args={{
		label: 'Northwind Traders International Logistics Division — West Coast Hub',
		doctype: 'contact'
	}}
	play={({ canvasElement }) => {
		const capsule = canvasElement.querySelector('.capsule') as HTMLElement;
		expect(capsule).not.toBeNull();
		// Visible label is truncated and ends with the ellipsis.
		expect(capsule.textContent ?? '').toContain('…');
		expect((capsule.textContent ?? '').length).toBeLessThan(60);
		// The full name is preserved as the hover tooltip title.
		expect(capsule.getAttribute('title')).toBe(
			'Northwind Traders International Logistics Division — West Coast Hub'
		);
	}}
/>
