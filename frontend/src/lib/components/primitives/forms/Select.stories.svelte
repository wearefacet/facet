<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, userEvent, fn, waitFor } from 'storybook/test';
	import * as m from '$lib/paraglide/messages';
	import Type from '@lucide/svelte/icons/type';
	import FileText from '@lucide/svelte/icons/file-text';
	import Hash from '@lucide/svelte/icons/hash';
	import Binary from '@lucide/svelte/icons/binary';
	import ToggleLeft from '@lucide/svelte/icons/toggle-left';
	import Calendar from '@lucide/svelte/icons/calendar';
	import Palette from '@lucide/svelte/icons/palette';
	import List from '@lucide/svelte/icons/list';
	import DollarSign from '@lucide/svelte/icons/dollar-sign';
	import Link from '@lucide/svelte/icons/link';
	import Globe from '@lucide/svelte/icons/globe';
	import Select from './Select.svelte';
	import type { SelectOption } from './Select.svelte';

	const statusOptions: SelectOption[] = [
		{ value: 'draft', label: 'Draft' },
		{ value: 'active', label: 'Active' },
		{ value: 'archived', label: 'Archived' }
	];

	const fieldTypeOptions: SelectOption[] = [
		{ value: 'string', label: 'String', icon: Type },
		{ value: 'longtext', label: 'Long Text', icon: FileText },
		{ value: 'integer', label: 'Integer', icon: Hash },
		{ value: 'float', label: 'Float', icon: Binary },
		{ value: 'boolean', label: 'Boolean', icon: ToggleLeft },
		{ value: 'datetime', label: 'Date & Time', icon: Calendar },
		{ value: 'color', label: 'Color', icon: Palette },
		{ value: 'enum', label: 'Enum', icon: List },
		{ value: 'money', label: 'Money', icon: DollarSign },
		{ value: 'reference', label: 'Reference', icon: Link }
	];

	// Timezone list, grouped by region, with one featured "automatic" entry.
	const timezoneOptions: SelectOption[] = [
		{ value: 'auto', label: 'Automatic (system timezone)', featured: true, icon: Globe },
		{
			group: 'Asia',
			options: [
				{ value: 'Asia/Tokyo', label: '(GMT+9) Tokyo' },
				{ value: 'Asia/Shanghai', label: '(GMT+8) Shanghai' },
				{ value: 'Asia/Singapore', label: '(GMT+8) Singapore' },
				{ value: 'Asia/Kolkata', label: '(GMT+5:30) Kolkata' },
				{ value: 'Asia/Dubai', label: '(GMT+4) Dubai' }
			]
		},
		{
			group: 'Europe',
			options: [
				{ value: 'Europe/London', label: '(GMT+0) London' },
				{ value: 'Europe/Paris', label: '(GMT+1) Paris' },
				{ value: 'Europe/Berlin', label: '(GMT+1) Berlin' },
				{ value: 'Europe/Madrid', label: '(GMT+1) Madrid' }
			]
		},
		{
			group: 'Americas',
			options: [
				{ value: 'America/New_York', label: '(GMT-5) New York' },
				{ value: 'America/Chicago', label: '(GMT-6) Chicago' },
				{ value: 'America/Los_Angeles', label: '(GMT-8) Los Angeles' },
				{ value: 'America/Sao_Paulo', label: '(GMT-3) São Paulo' }
			]
		},
		{
			group: 'Oceania',
			options: [
				{ value: 'Australia/Sydney', label: '(GMT+11) Sydney' },
				{ value: 'Pacific/Auckland', label: '(GMT+13) Auckland' }
			]
		}
	];

	const currencyOptions: SelectOption[] = [
		{ value: 'usd', label: 'USD — US Dollar', featured: true },
		{ value: 'eur', label: 'EUR — Euro', featured: true },
		{ value: 'gbp', label: 'GBP — British Pound', featured: true },
		{ value: 'jpy', label: 'JPY — Japanese Yen' },
		{ value: 'cny', label: 'CNY — Chinese Yuan' },
		{ value: 'cad', label: 'CAD — Canadian Dollar' },
		{ value: 'aud', label: 'AUD — Australian Dollar' },
		{ value: 'chf', label: 'CHF — Swiss Franc' },
		{ value: 'inr', label: 'INR — Indian Rupee' },
		{ value: 'brl', label: 'BRL — Brazilian Real' }
	];

	const { Story } = defineMeta({
		title: 'Components/Primitives/Forms/Select',
		component: Select,
		tags: ['autodocs'],
		args: {
			onchange: fn(),
			onValueChange: fn()
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});
</script>

<script lang="ts">
	// Late-resolved label fixture: the selected value starts on the fallback
	// label (the bare ticker), then the "registry" resolves the display name
	// after mount — the shape the currency picker hits when its lazy load
	// lands after the first render.
	let lateResolved = $state(false);
	$effect(() => {
		const id = setTimeout(() => (lateResolved = true), 30);
		return () => clearTimeout(id);
	});
	const lateResolvedOptions = $derived<SelectOption[]>(
		lateResolved ? [{ value: 'EUR', label: 'Euro' }] : [{ value: 'EUR', label: 'EUR' }]
	);
</script>

<!-- 1. Default ----------------------------------------------------------- -->
<Story
	name="Default"
	args={{
		label: 'Status',
		options: statusOptions,
		placeholder: 'Pick a status…'
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Status')).toBeVisible();
		await expect(canvas.getByPlaceholderText('Pick a status…')).toBeVisible();
	}}
/>

<!-- 2. WithValue -------------------------------------------------------- -->
<Story
	name="WithValue"
	args={{
		label: 'Status',
		options: statusOptions,
		value: 'active'
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByLabelText('Status')).toHaveValue('Active');
	}}
/>

<!-- 3. Typeable filtering ------------------------------------------------ -->
<Story
	name="TypeableFiltering"
	args={{
		label: 'Timezone',
		options: timezoneOptions,
		placeholder: 'Type to filter…'
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const input = canvas.getByLabelText('Timezone');
		await userEvent.click(input);
		await userEvent.type(input, 'tok');
		// Portal renders to document.body — search there, not the canvas.
		const body = within(document.body);
		// Only the Tokyo entry survives the filter.
		await waitFor(() => {
			expect(body.getByText('(GMT+9) Tokyo')).toBeVisible();
		});
		// Other regions are filtered out.
		expect(body.queryByText('(GMT+0) London')).toBeNull();
	}}
/>

<!-- 4. Grouped with featured -------------------------------------------- -->
<Story
	name="GroupedFeatured"
	args={{
		label: 'Timezone',
		options: timezoneOptions,
		placeholder: 'Select your timezone…',
		helper: 'Featured entries are pinned with an accent marker.'
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const input = canvas.getByLabelText('Timezone');
		await userEvent.click(input);
		await userEvent.keyboard('{ArrowDown}');
		// Portal renders to document.body — search there, not the canvas.
		const body = within(document.body);
		// Featured "Automatic" entry is visible and carries data-featured.
		await waitFor(() => {
			expect(body.getByText('Automatic (system timezone)')).toBeVisible();
		});
		const featured = document.body.querySelector('[data-featured]');
		expect(featured).not.toBeNull();
		// A group heading is rendered.
		expect(body.getByText('Asia')).toBeVisible();
	}}
/>

<!-- 5. Featured items (currencies) -------------------------------------- -->
<Story
	name="FeaturedItems"
	args={{
		label: 'Currency',
		options: currencyOptions,
		placeholder: 'Pick a currency…'
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const input = canvas.getByLabelText('Currency');
		await userEvent.click(input);
		await userEvent.keyboard('{ArrowDown}');
		// Portal renders to document.body — search there, not the canvas.
		const body = within(document.body);
		await waitFor(() => {
			expect(body.getByText('USD — US Dollar')).toBeVisible();
		});
		// Three featured entries carry data-featured.
		expect(document.body.querySelectorAll('[data-featured]').length).toBe(3);
	}}
/>

<!-- 6. WithIcons -------------------------------------------------------- -->
<Story
	name="WithIcons"
	args={{
		label: 'Field Type',
		options: fieldTypeOptions,
		placeholder: 'Pick a field type…',
		helper: 'Each field type uses a distinct icon'
	}}
/>

<!-- 7. WithIconsValue --------------------------------------------------- -->
<Story
	name="WithIconsValue"
	args={{
		label: 'Field Type',
		options: fieldTypeOptions,
		value: 'boolean'
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByLabelText('Field Type')).toHaveValue('Boolean');
	}}
/>

<!-- 8. WithHelper ------------------------------------------------------- -->
<Story
	name="WithHelper"
	args={{
		label: 'Role',
		options: [
			{ value: 'admin', label: 'Administrator' },
			{ value: 'editor', label: 'Editor' },
			{ value: 'viewer', label: 'Viewer' }
		],
		helper: 'Controls what this user can see and do'
	}}
/>

<!-- 9. WithError -------------------------------------------------------- -->
<Story
	name="WithError"
	args={{
		label: 'Country',
		options: [
			{ value: 'us', label: 'United States' },
			{ value: 'ca', label: 'Canada' },
			{ value: 'mx', label: 'Mexico' }
		],
		error: 'Please select a country'
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Please select a country')).toBeVisible();
	}}
/>

<!-- 10. Disabled -------------------------------------------------------- -->
<Story
	name="Disabled"
	args={{
		label: 'Status',
		options: statusOptions,
		value: 'draft',
		disabled: true
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByLabelText('Status')).toBeDisabled();
	}}
/>

<!-- 11. Required -------------------------------------------------------- -->
<Story name="Required" args={{ label: 'Department', options: statusOptions, required: true }} />

<!-- 12. NotSearchable ---------------------------------------------------- -->
<Story
	name="NotSearchable"
	args={{
		label: 'Priority',
		options: [
			{ value: 'low', label: 'Low' },
			{ value: 'med', label: 'Medium' },
			{ value: 'high', label: 'High' }
		],
		searchable: false,
		placeholder: 'Pick a priority…'
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const input = canvas.getByLabelText('Priority');
		// Input is read-only: typing does not change its value.
		await userEvent.type(input, 'xyz');
		expect(input).toHaveValue('');
		expect(input).toHaveAttribute('readonly');
	}}
/>

<!-- 13. AsyncSearch (simulated server round-trip) ----------------------- -->
<Story
	name="AsyncSearch"
	args={{
		label: 'Find invoice',
		placeholder: 'Search by invoice #…',
		onsearch: fn(),
		results: [] as SelectOption[]
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const input = canvas.getByLabelText('Find invoice');
		await userEvent.click(input);
		await userEvent.type(input, 'maersk');
		await waitFor(() => {
			expect(args.onsearch).toHaveBeenCalledWith('maersk');
		});
		// The template's onsearch fires a setTimeout(200) to populate results.
		// Wait for the simulated server response.
		const body = within(document.body);
		await waitFor(() => {
			expect(body.getByText('INV-2026-0488 — Maersk Line A/S')).toBeVisible();
		});
	}}
>
	{#snippet template(args)}
		<div
			style="position: relative; width: 100%; height: 80vh; min-height: 500px; overflow: hidden;"
		>
			<div style="max-width: 360px; padding: 24px;">
				<Select
					label={args.label}
					placeholder={args.placeholder}
					onsearch={(q) => {
						args.onsearch?.(q);
						// Simulate server round-trip: clear then populate results.
						args.results = [];
						setTimeout(() => {
							const all = [
								{ value: '1', label: 'INV-2026-0488 — Maersk Line A/S' },
								{ value: '2', label: 'INV-2026-0472 — Maersk Container' },
								{ value: '3', label: 'INV-2026-0512 — Hapag-Lloyd AG' },
								{ value: '4', label: 'INV-2026-0391 — MSC Mediterranean Shipping' },
								{ value: '5', label: 'INV-2026-0623 — CMA CGM Group' },
								{ value: '6', label: 'INV-2026-0447 — COSCO Shipping Lines' },
								{ value: '7', label: 'INV-2026-0578 — Evergreen Marine' },
								{ value: '8', label: 'INV-2026-0335 — Ocean Network Express' },
								{ value: '9', label: 'INV-2026-0701 — Yang Ming Marine Transport' },
								{ value: '10', label: 'INV-2026-0284 — ZIM Integrated Shipping' },
								{ value: '11', label: 'INV-2026-0159 — Hamburg Süd' },
								{ value: '12', label: 'INV-2026-0617 — PIL Pacific International Lines' }
							];
							const ql = q.toLowerCase();
							args.results = all.filter(
								(r) => r.label.toLowerCase().includes(ql) || r.value.toLowerCase().includes(ql)
							);
						}, 200);
					}}
					results={args.results}
				/>
			</div>
		</div>
	{/snippet}
</Story>

<!-- 14. AsyncLoading ---------------------------------------------------- -->
<Story
	name="AsyncLoading"
	args={{
		label: 'Find invoice',
		placeholder: 'Search by invoice #…',
		onsearch: fn(),
		loading: true,
		results: [] as SelectOption[]
	}}
>
	{#snippet template(args)}
		<div
			style="position: relative; width: 100%; height: 80vh; min-height: 500px; overflow: hidden;"
		>
			<div style="max-width: 360px; padding: 24px;">
				<Select
					label={args.label}
					placeholder={args.placeholder}
					onsearch={(q) => args.onsearch?.(q)}
					results={args.results}
				/>
			</div>
		</div>
	{/snippet}
</Story>

<!-- 15. AsyncEmpty ------------------------------------------------------ -->
<Story
	name="AsyncEmpty"
	args={{
		label: 'Find invoice',
		placeholder: 'Search by invoice #…',
		onsearch: fn(),
		results: [] as SelectOption[]
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const input = canvas.getByLabelText('Find invoice');
		await userEvent.click(input);
		await userEvent.keyboard('{ArrowDown}');
		// Portal renders to document.body — search there, not the canvas.
		const body = within(document.body);
		await waitFor(() => {
			expect(body.getByText('No options')).toBeVisible();
		});
	}}
>
	{#snippet template(args)}
		<div
			style="position: relative; width: 100%; height: 80vh; min-height: 500px; overflow: hidden;"
		>
			<div style="max-width: 360px; padding: 24px;">
				<Select
					label={args.label}
					placeholder={args.placeholder}
					onsearch={(q) => args.onsearch?.(q)}
					results={args.results}
				/>
			</div>
		</div>
	{/snippet}
</Story>

<!-- 16. AsyncWithResults (server-driven list) -------------------------- -->
<Story
	name="AsyncWithResults"
	args={{
		label: 'Find invoice',
		placeholder: 'Search by invoice #…',
		onsearch: fn(),
		results: [
			{ value: '1', label: 'INV-2026-0488 — Maersk Line A/S' },
			{ value: '2', label: 'INV-2026-0472 — Maersk Container' }
		] as SelectOption[]
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const input = canvas.getByLabelText('Find invoice');
		await userEvent.click(input);
		await userEvent.keyboard('{ArrowDown}');
		// Portal renders to document.body — search there, not the canvas.
		const body = within(document.body);
		await waitFor(() => {
			expect(body.getByText('INV-2026-0488 — Maersk Line A/S')).toBeVisible();
		});
	}}
>
	{#snippet template(args)}
		<div
			style="position: relative; width: 100%; height: 80vh; min-height: 500px; overflow: hidden;"
		>
			<div style="max-width: 360px; padding: 24px;">
				<Select
					label={args.label}
					placeholder={args.placeholder}
					onsearch={(q) => args.onsearch?.(q)}
					results={args.results}
				/>
			</div>
		</div>
	{/snippet}
</Story>

<!-- 17. Typed text commits when it names exactly one option (B-290) ----- -->
<Story
	name="TypedMatchCommits"
	args={{
		label: 'Status',
		options: statusOptions,
		placeholder: 'Pick a status…'
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const input = canvas.getByLabelText('Status');
		await userEvent.type(input, 'archived');
		await userEvent.keyboard('{Enter}');
		// The typed label commits to the bound value — the form state keeps
		// it (the save path reads the bound value, not the input text).
		await waitFor(() => {
			expect(args.onValueChange).toHaveBeenCalledWith('archived');
		});
		await expect(input).toHaveValue('Archived');
	}}
/>

<!-- 18. Typed text matching no option shows a field error (B-290) ------- -->
<Story
	name="TypedNoMatchShowsError"
	args={{
		label: 'Status',
		options: statusOptions,
		placeholder: 'Pick a status…'
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const input = canvas.getByLabelText('Status');
		await userEvent.type(input, 'zzz');
		// Blur is the commit point — the non-matching text stays visible but
		// is marked with a field error, and nothing binds.
		await userEvent.tab();
		await expect(canvas.getByRole('alert')).toHaveTextContent(m.form_select_no_match());
		expect(args.onValueChange).not.toHaveBeenCalled();
	}}
/>

<!-- 19. Late-resolved label re-syncs the input (F07-05 currency registry) -- -->
<!-- A lazily loaded option list resolves the selected value's display label -->
<!-- after the first render (the currency registry load). The input must -->
<!-- follow the resolved label, not stay on the raw value. -->
<Story
	name="LateResolvedLabel"
	args={{}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const input = canvas.getByLabelText('Currency');
		// Starts on the fallback label (the bare ticker)…
		await expect(input).toHaveValue('EUR');
		// …then the registry resolves the display name.
		await waitFor(() => {
			expect(input).toHaveValue('Euro');
		});
	}}
>
	{#snippet template()}
		<div style="padding: 24px; max-width: 360px;">
			<Select
				label="Currency"
				value="EUR"
				options={lateResolvedOptions}
				placeholder="Pick a currency…"
			/>
		</div>
	{/snippet}
</Story>
