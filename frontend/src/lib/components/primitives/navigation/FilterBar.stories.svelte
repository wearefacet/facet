<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, fireEvent, waitFor, within } from 'storybook/test';
	import FilterBar from './FilterBar.svelte';
	import { createMockDriver } from '$lib/datasource/mock-seed.js';
	import { parseDoctypeDef, type DoctypeDef } from '$lib/doctype/types.js';

	const driver = createMockDriver();
	const rawDef = driver.getDoctypeDefinition('crm.Deal');
	const doctype: DoctypeDef | undefined = rawDef
		? parseDoctypeDef(rawDef as Record<string, unknown>)
		: undefined;

	// crm.Company declares a `search` template, so FilterBar renders its
	// search box for it (crm.Deal does not).
	const rawCompanyDef = driver.getDoctypeDefinition('crm.Company');
	const companyDoctype: DoctypeDef | undefined = rawCompanyDef
		? parseDoctypeDef(rawCompanyDef as Record<string, unknown>)
		: undefined;

	// Hand-built schema with a boolean field. No mock-seed doctype carries
	// one, and the boolean value control keys on the field type.
	const boolDoctype: DoctypeDef = {
		domain: 'crm',
		doctype: 'Flag',
		fields: [{ key: 'active', type: 'boolean', title: 'Active', operators: ['eq', 'ne'] }],
		children: [],
		actions: []
	};

	// Hand-built schema with a money field declaring the `currency`
	// capability, so the chip's operator dropdown offers the currency
	// operator beside the amount comparisons.
	const moneyDoctype: DoctypeDef = {
		domain: 'crm',
		doctype: 'Priced',
		fields: [
			{
				key: 'value',
				type: 'money',
				title: 'Deal Value',
				operators: ['eq', 'gt', 'gte', 'lt', 'lte', 'between', 'currency']
			}
		],
		children: [],
		actions: []
	};

	const { Story } = defineMeta({
		title: 'Components/Primitives/Navigation/FilterBar',
		component: FilterBar,
		tags: ['autodocs'],
		args: {
			driver,
			doctype
		}
	});

	// Spy capture for the search story (reset inside the play function) —
	// the `onFilterChange` seam, mirroring the driver's `listCalls` pattern.
	const searchFilterCalls: Array<Record<string, unknown>> = [];
	// Spy capture for the not-equal story (same seam).
	const neFilterCalls: Array<Record<string, unknown>> = [];
	// Spy capture for the greater/less story (same seam).
	const gtltFilterCalls: Array<Record<string, unknown>> = [];
	// Spy capture for the add-filter menu story (same seam).
	const addFilterCalls: Array<Record<string, unknown>> = [];
	// Spy capture for the `in` multi-select story (same seam).
	const inFilterCalls: Array<Record<string, unknown>> = [];
	// Spy capture for the boolean dropdown story (same seam).
	const booleanFilterCalls: Array<Record<string, unknown>> = [];
	// Spy capture for the currency picker story (same seam).
	const currencyFilterCalls: Array<Record<string, unknown>> = [];
	/** Small settle budget for portalled dropdown interactions. */
	const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));
</script>

<script lang="ts">
	import { userEvent } from 'storybook/test';
	import { filterBag, replaceBag } from './filter-bag.svelte.js';
</script>

<!--
	FilterBar is the reusable, schema-aware filter surface (search box +
	"+ Add filter" menu + one chip per active filter). It is used by the table
	toolbar and by the calendar view configuration. Filters are controlled:
	the parent owns the `filters` map and reflects it back through
	`onFilterChange`.
-->

<Story
	name="Empty"
	args={{
		filters: {},
		onFilterChange: (_next: Record<string, unknown>) => {}
	}}
/>

<Story
	name="WithActiveEnumFilter"
	args={{
		filters: { status__eq: 'open' },
		onFilterChange: (_next: Record<string, unknown>) => {}
	}}
/>

<Story
	name="NotEqualOperator"
	args={{
		filters: { status__eq: 'open' },
		onFilterChange: (next: Record<string, unknown>) => {
			neFilterCalls.push({ ...next });
		}
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		neFilterCalls.length = 0;
		// crm.Deal.status derives the full comparison family, so the chip's
		// operator dropdown offers the exclusion operator.
		const selects = canvas.getAllByRole('combobox');
		await userEvent.click(selects[0]);
		await sleep(60);
		// The dropdown portals to document.body — pick "is not" there.
		const body = within(document.body);
		await userEvent.click(body.getByRole('option', { name: 'is not' }));
		await sleep(40);
		// The filter key switched from `status__eq` to `status__ne` (the value
		// resets on an operator change — different operators need different
		// value shapes) and the operator trigger reads "is not".
		await waitFor(() => {
			const emitted = neFilterCalls.at(-1);
			expect(emitted && 'status__ne' in emitted).toBe(true);
			expect(emitted && 'status__eq' in emitted).toBe(false);
		});
		await expect(canvas.getByText('Status')).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; background: var(--ground);">
			<FilterBar {doctype} {driver} filters={args.filters} onFilterChange={args.onFilterChange} />
		</div>
	{/snippet}
</Story>

<Story
	name="GreaterLessOperators"
	args={{
		filters: { probability__gt: '50' },
		onFilterChange: (next: Record<string, unknown>) => {
			gtltFilterCalls.push({ ...next });
		}
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		gtltFilterCalls.length = 0;
		// crm.Deal.probability declares the comparison family, so the bar
		// offers the strict comparisons beside gte/lte. The chip renders the
		// field title and the '>' operator trigger over a number input.
		await expect(canvas.getByText('Probability')).toBeVisible();
		// The operator control is the shared Combobox-style Select — the
		// selected label renders as the input's value ('>'), not text content.
		const trigger = canvas.getByRole('combobox');
		await expect(trigger).toHaveValue('>');
		// Switching to '<' re-keys the filter from `probability__gt` to
		// `probability__lt` (the value resets — scalar shapes, new key).
		await userEvent.click(trigger);
		await sleep(60);
		// The dropdown portals to document.body — pick '<' there.
		const body = within(document.body);
		await userEvent.click(body.getByRole('option', { name: '<' }));
		await sleep(40);
		await waitFor(() => {
			const emitted = gtltFilterCalls.at(-1);
			expect(emitted && 'probability__lt' in emitted).toBe(true);
			expect(emitted && 'probability__gt' in emitted).toBe(false);
		});
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; background: var(--ground);">
			<FilterBar {doctype} {driver} filters={args.filters} onFilterChange={args.onFilterChange} />
		</div>
	{/snippet}
</Story>

<Story
	name="AddFilterClosesMenu"
	args={{
		filters: {},
		onFilterChange: (next: Record<string, unknown>) => {
			addFilterCalls.push({ ...next });
		}
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		addFilterCalls.length = 0;
		// Open the "+ Add filter" menu — it portals to document.body.
		await userEvent.click(canvas.getByRole('button', { name: '+ Add filter' }));
		await sleep(60);
		const body = within(document.body);
		const item = body.getByRole('menuitem', { name: 'Status' });
		await userEvent.click(item);
		// Picking a field emits the chip's initial filter…
		await waitFor(() => {
			const emitted = addFilterCalls.at(-1);
			expect(emitted && 'status__eq' in emitted).toBe(true);
		});
		// …and closes the menu — the toolbar row is usable again without
		// Escape or an outside click.
		await waitFor(() => {
			expect(body.queryByRole('menuitem', { name: 'Status' })).toBeNull();
		});
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; background: var(--ground);">
			<FilterBar {doctype} {driver} filters={args.filters} onFilterChange={args.onFilterChange} />
		</div>
	{/snippet}
</Story>

<Story
	name="InOperatorMultiSelect"
	args={{
		filters: { status__in: [] }
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		inFilterCalls.length = 0;
		await expect(canvas.getByText('Status')).toBeVisible();
		// The multi-select trigger (a labelled button) opens the portalled
		// listbox; the empty selection shows the pick placeholder.
		const trigger = canvas.getByRole('button', { name: 'Filter values for Status' });
		await expect(trigger).toHaveTextContent('Pick…');
		await userEvent.click(trigger);
		await sleep(60);
		const body = within(document.body);
		// Multi-select two values — the menu stays open between picks.
		await userEvent.click(body.getByRole('option', { name: 'Open' }));
		await sleep(40);
		await userEvent.click(body.getByRole('option', { name: 'Won' }));
		await sleep(40);
		// Selections emit as the `status__in` array (order-insensitive — the
		// backend `= ANY(ARRAY[...])` compares membership, not order).
		await waitFor(() => {
			const emitted = inFilterCalls.at(-1)?.['status__in'];
			expect(Array.isArray(emitted)).toBe(true);
			expect((emitted as string[]).slice().sort()).toEqual(['open', 'won'].sort());
		});
		// The trigger shows the picked labels.
		await expect(trigger).toHaveTextContent('Open');
		// Close the menu, then switch the operator away — the array key drops
		// and the scalar shape takes over with a fresh initial value.
		await userEvent.keyboard('{Escape}');
		await sleep(40);
		await userEvent.click(canvas.getByRole('combobox'));
		await sleep(60);
		await userEvent.click(body.getByRole('option', { name: 'is' }));
		await sleep(40);
		await waitFor(() => {
			const emitted = inFilterCalls.at(-1);
			expect(emitted && 'status__in' in emitted).toBe(false);
			expect(emitted?.['status__eq']).toBe('');
		});
	}}
>
	{#snippet template(args)}
		{@const bag = filterBag(args.filters ?? {})}
		<div style="padding: 24px; background: var(--ground);">
			<FilterBar
				{doctype}
				{driver}
				filters={bag}
				onFilterChange={(next) => {
					// Record the emission (the assertion seam) and reflect it back
					// into the bag — the controlled contract a real parent keeps.
					inFilterCalls.push({ ...next });
					replaceBag(bag, next);
				}}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="BooleanValueDropdown"
	args={{
		filters: { active__eq: 'true' },
		onFilterChange: (next: Record<string, unknown>) => {
			booleanFilterCalls.push({ ...next });
		}
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		booleanFilterCalls.length = 0;
		// A boolean chip reads 'is' / 'is not' (the enum/reference words) and
		// renders the value as a True/False dropdown — no free-text 'true'.
		await expect(canvas.getByText('Active')).toBeVisible();
		const selects = canvas.getAllByRole('combobox');
		await expect(selects[0]).toHaveValue('is');
		await expect(selects[1]).toHaveValue('True');
		// Picking 'False' emits the string 'false' — the same wire form a
		// typed 'true'/'false' text filter always produced.
		await userEvent.click(selects[1]);
		await sleep(60);
		// The dropdown portals to document.body — pick 'False' there.
		const body = within(document.body);
		await userEvent.click(body.getByRole('option', { name: 'False' }));
		await sleep(40);
		await waitFor(() => {
			expect(booleanFilterCalls.at(-1)?.['active__eq']).toBe('false');
		});
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; background: var(--ground);">
			<FilterBar
				doctype={boolDoctype}
				{driver}
				filters={args.filters}
				onFilterChange={args.onFilterChange}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="CurrencyValuePicker"
	args={{
		doctype: moneyDoctype,
		filters: { value__currency: 'EUR' },
		onFilterChange: (next: Record<string, unknown>) => {
			currencyFilterCalls.push({ ...next });
		}
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		currencyFilterCalls.length = 0;
		// The currency chip renders the field title over the 'is' operator and
		// a currency dropdown seeded with the stored ticker.
		await expect(canvas.getByText('Deal Value')).toBeVisible();
		const selects = canvas.getAllByRole('combobox');
		await expect(selects[0]).toHaveValue('is');
		// Picking a ticker emits it as the `value__currency` value — the wire
		// form the backend money clause compares against the stored currency
		// member (and the mock mirrors).
		await userEvent.click(selects[1]);
		await sleep(60);
		const body = within(document.body);
		// The currency registry labels the option by its display name ('US
		// Dollar'), not the bare ticker; picking it emits the ticker as the
		// `value__currency` value.
		await userEvent.click(body.getByRole('option', { name: 'US Dollar' }));
		await sleep(40);
		await waitFor(() => {
			expect(currencyFilterCalls.at(-1)?.['value__currency']).toBe('USD');
		});
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; background: var(--ground);">
			<FilterBar
				doctype={moneyDoctype}
				{driver}
				filters={args.filters}
				onFilterChange={args.onFilterChange}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="SearchEmitsBareSearchKey"
	args={{
		doctype: companyDoctype,
		filters: {},
		onFilterChange: (next: Record<string, unknown>) => {
			searchFilterCalls.push({ ...next });
		}
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const input = await canvas.findByPlaceholderText('Search…');

		searchFilterCalls.length = 0;
		await fireEvent.input(input, { target: { value: 'acme' } });

		// The search box debounces (~250 ms) before emitting. The emitted
		// key must be the bare `search` operator — a suffixed form
		// (`search__match`, …) is not a production of the filter grammar.
		await waitFor(() => {
			const emitted = searchFilterCalls.at(-1);
			expect(emitted?.['search']).toBe('acme');
			expect(emitted && 'search__match' in emitted).toBe(false);
		});
	}}
/>
