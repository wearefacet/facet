<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, fireEvent, waitFor, within } from 'storybook/test';
	import ReferencePicker from './ReferencePicker.svelte';
	import { createMockDriver } from '$lib/datasource/mock-seed.js';
	import { MockDataDriver } from '$lib/datasource/MockDriver.js';
	import type { MockDataSource } from '$lib/datasource/MockDataSource.js';
	import type { ListParams } from '$lib/datasource/types.js';

	const driver = createMockDriver();

	// A template-less doctype for the IdFallback story (B-296): no
	// `display_name` and no `search`, so the picker falls back to ids. A
	// dedicated driver keeps the `core.DocType` list to the one target the
	// story needs (its row carries no template fields).
	const idDriver = new MockDataDriver();
	idDriver.registerDoctype('crm', 'LegacyNote', {
		domain: 'crm',
		doctype: 'LegacyNote',
		fields: { body: { type: 'string' } }
	});
	idDriver.domain('crm').doctype('LegacyNote', [
		{ id: 'crm.LegacyNote.note-1', body: 'Old note' },
		{ id: 'crm.LegacyNote.note-2', body: 'Another old note' }
	]);
	idDriver
		.domain('core')
		.doctype('DocType', [{ id: 'crm.LegacyNote', domain: 'crm', doctype: 'LegacyNote' }]);

	const { Story } = defineMeta({
		title: 'Components/Primitives/Forms/ReferencePicker',
		component: ReferencePicker,
		tags: ['autodocs'],
		args: {
			driver
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});
</script>

<Story
	name="Forced"
	args={{ label: 'Linked company', doctype: 'crm.Company', placeholder: 'Search companies…' }}
/>

<Story
	name="ForcedSelected"
	args={{
		label: 'Linked company',
		doctype: 'crm.Company',
		value: 'crm.Company.1',
		placeholder: 'Search companies…'
	}}
	play={async ({ canvasElement }) => {
		const _canvas = within(canvasElement);
		await waitFor(() => {
			// Chip should hydrate from `value` to the company's display_name.
			const label = canvasElement.querySelector('.ref-capsule-label');
			expect(label?.textContent ?? '').toBe('Acme Corp');
		});
		// The raw id must never appear inside the chip.
		const capsule = canvasElement.querySelector('.ref-capsule');
		expect(capsule?.textContent ?? '').not.toContain('crm.Company.1');
	}}
/>

<!--
	RecordMetaOverride — the optional `recordMeta` prop overrides the chip's
	label and mark per record id. Here the picked company wears its own tint
	and label instead of the declared target type's (crm.Company's mark).
-->
<Story
	name="RecordMetaOverride"
	args={{
		label: 'Linked company',
		doctype: 'crm.Company',
		value: 'crm.Company.1',
		placeholder: 'Search companies…',
		recordMeta: {
			'crm.Company.1': { label: 'Acme Corp · verified', icon: 'shield-check', color: '#176e3a' }
		}
	}}
	play={async ({ canvasElement }) => {
		await waitFor(() => {
			const label = canvasElement.querySelector('.ref-capsule-label');
			expect(label?.textContent ?? '').toBe('Acme Corp · verified');
		});
		// The chip wears the override tint, not the declared type's blue.
		const capsule = canvasElement.querySelector('.ref-capsule');
		expect(capsule?.getAttribute('style')).toContain('#176e3a');
	}}
/>

<Story
	name="UnresolvedReference"
	args={{
		label: 'Linked company',
		doctype: 'crm.Company',
		value: 'crm.Company.does-not-exist',
		placeholder: 'Search companies…'
	}}
	play={async ({ canvasElement }) => {
		// Hydration fails; the chip falls back to the id portion of the value.
		await waitFor(() => {
			const label = canvasElement.querySelector('.ref-capsule-label');
			expect(label?.textContent ?? '').toBe('does-not-exist');
		});
	}}
/>

<!--
	IdFallback — a template-less target (no `display_name`/`search`) has no
	search corpus, so the bare `search` filter matches only the row id. The
	picker labels results by id and steers the user to search by id (B-296).
-->
<Story
	name="IdFallback"
	args={{
		label: 'Legacy note',
		doctype: 'crm.LegacyNote',
		placeholder: 'Search by id…',
		driver: idDriver
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);

		const input = await canvas.findByPlaceholderText('Search by id…');
		await fireEvent.focus(input);

		// The dropdown opens with the id-oriented hint (no label template).
		await waitFor(() => {
			const hint = canvasElement.querySelector('.ref-hint');
			expect(hint?.textContent ?? '').toContain('search by id');
		});

		// Results label by id, never by a (missing) display_name.
		await waitFor(() => {
			const rows = canvasElement.querySelectorAll('.ref-opt .ref-capsule-label');
			const labels = Array.from(rows).map((r) => r.textContent ?? '');
			expect(labels).toContain('crm.LegacyNote.note-1');
		});
	}}
/>

<Story
	name="Constrained"
	args={{ label: 'Reference', doctypes: ['crm.Prospect', 'crm.Customer'] }}
/>

<Story name="Open" args={{ label: 'Reference' }} />

<Story
	name="WithError"
	args={{ label: 'Company', doctype: 'crm.Company', error: 'This field is required.' }}
/>

<Story name="Disabled" args={{ label: 'Company', doctype: 'crm.Company', disabled: true }} />

<Story
	name="SearchDelegatesToBackend"
	args={{
		label: 'Linked company',
		doctype: 'crm.Company',
		placeholder: 'Search companies…'
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);

		// Grab the MockDataSource backing `crm.Company` so we can spy on `list`.
		const companyDs = driver.domain('crm').doctype('Company') as unknown as MockDataSource;

		// Reset the spy so prior stories don't pollute the assertion.
		companyDs.listCalls.length = 0;

		const input = await canvas.findByPlaceholderText('Search companies…');
		await fireEvent.focus(input);
		await fireEvent.input(input, { target: { value: 'acme' } });

		// The picker debounces search (~220ms) before calling `ds.list`.
		await waitFor(() => {
			const searched = companyDs.listCalls.filter(
				(call: ListParams) =>
					call.items === 25 &&
					(call.filters as Record<string, unknown> | undefined)?.search === 'acme'
			);
			expect(searched.length).toBeGreaterThan(0);
		});

		// Empty queries (dropdown-open prefetch) must NOT carry a `search` filter.
		const emptyQueryCalls = companyDs.listCalls.filter(
			(call: ListParams) =>
				(call.filters as Record<string, unknown> | undefined)?.search === undefined
		);
		expect(emptyQueryCalls.length).toBeGreaterThan(0);
	}}
/>

<!--
	FilteredReference — the `filter` prop (sourced from a doctype definition's
	`filter:` block) is merged into every `list()` call alongside the text search.
	Only `crm.Company` documents with `status: active` (Acme Corp) should appear.
-->
<Story
	name="FilteredReference"
	args={{
		label: 'Active company',
		doctype: 'crm.Company',
		placeholder: 'Search active companies…',
		filter: { status__eq: 'active' }
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);

		const companyDs = driver.domain('crm').doctype('Company') as unknown as MockDataSource;
		companyDs.listCalls.length = 0;

		const input = await canvas.findByPlaceholderText('Search active companies…');
		await fireEvent.focus(input);

		// The dropdown-open prefetch issues a `list()` with the filter merged in.
		await waitFor(() => {
			const filtered = companyDs.listCalls.filter(
				(call: ListParams) =>
					(call.filters as Record<string, unknown> | undefined)?.status__eq === 'active'
			);
			expect(filtered.length).toBeGreaterThan(0);
		});

		// A text search must combine with the filter, not replace it.
		companyDs.listCalls.length = 0;
		await fireEvent.input(input, { target: { value: 'acme' } });
		await waitFor(() => {
			const combined = companyDs.listCalls.filter(
				(call: ListParams) =>
					(call.filters as Record<string, unknown> | undefined)?.status__eq === 'active' &&
					(call.filters as Record<string, unknown> | undefined)?.search === 'acme'
			);
			expect(combined.length).toBeGreaterThan(0);
		});

		// And the returned results must actually match the filter: only Acme Corp
		// has `status: active` in the seeded Company fixtures.
		await waitFor(() => {
			const items = canvas.queryAllByText('Acme Corp');
			expect(items.length).toBeGreaterThan(0);
			expect(canvas.queryByText('Globex Inc')).toBeNull();
			expect(canvas.queryByText('Initech')).toBeNull();
		});
	}}
/>
