<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, userEvent, waitFor } from 'storybook/test';
	import MoneyInput from './MoneyInput.svelte';
	import {
		seedCurrencies,
		currencyRowsFromMockDriver,
		type CurrencyRecord
	} from '$lib/components/primitives/data/currencyStore.svelte.js';
	import { createMockDriver } from '$lib/datasource/mock-seed.js';

	// The preview loader seeds the store from the mock driver before every
	// story. The two stories that need a different row set (an inactive row;
	// an emptied store) re-seed at the top of their play — plays run after the
	// render, so every read from the component (dropdown options, flagged
	// inactive state) sees the override reactively.
	const seedRows = currencyRowsFromMockDriver(createMockDriver());

	// The inactive-current story adds a deactivated row (FRF) the seed does
	// not carry.
	const rowsWithInactive: CurrencyRecord[] = [
		...seedRows,
		{
			ticker: 'FRF',
			symbol: '₣',
			name: 'French Franc',
			digits: 2,
			grouping: 'standard',
			active: false,
			favorite: false
		}
	];

	const { Story } = defineMeta({
		title: 'Components/Primitives/Forms/MoneyInput',
		component: MoneyInput,
		tags: ['autodocs'],
		argTypes: {
			value: { control: 'object' }
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});
</script>

<Story
	name="EmptyDefault"
	args={{ label: 'Budget' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The untouched field reads as chrome: a neutral "Currency" placeholder.
		await expect(canvas.getByText('Currency')).toBeVisible();
		// Typing an amount commits the default (EUR) ticker.
		const amountInput = canvas.getByPlaceholderText('0');
		await amountInput.focus();
		await userEvent.type(amountInput, '100');
		await expect(canvas.getByText('EUR')).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div class="money-story-frame">
			<MoneyInput label={args.label} placeholder="0" />
		</div>
	{/snippet}
</Story>

<Story
	name="ScopedIdsAcrossRows"
	play={async ({ canvasElement }) => {
		// Two rows render the same field label — the inline child-row shape.
		// The id scope keeps the DOM ids unique and every <label for>
		// association valid (B-394). The amount inputs are matched by id — the
		// field group carries the same accessible name, so label queries would
		// also hit the group wrappers.
		const ids = ['money-input-row-1-Amount', 'money-input-row-2-Amount'];
		for (const id of ids) {
			const matches = canvasElement.querySelectorAll(`[id="${id}"]`);
			expect(matches).toHaveLength(1);
			const input = matches[0] as HTMLInputElement;
			expect(input.tagName).toBe('INPUT');
			// The visible label points at this input.
			const label = canvasElement.querySelector(`label[for="${id}"]`);
			expect(label?.textContent?.trim()).toBe('Amount');
		}
		// No duplicate ids anywhere in the story.
		const all = [...canvasElement.querySelectorAll('input')];
		expect(new Set(all.map((el) => el.id)).size).toBe(all.length);
	}}
>
	{#snippet template()}
		<div class="money-story-frame" style="display: grid; gap: 12px;">
			<MoneyInput label="Amount" idScope="row-1" placeholder="0" />
			<MoneyInput label="Amount" idScope="row-2" placeholder="0" />
		</div>
	{/snippet}
</Story>

<Story
	name="FavoritesOnTop"
	args={{ label: 'Budget' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const currencyButton = canvas.getByRole('button', { name: 'Select currency' });
		await currencyButton.click();
		const opts = canvas.getAllByRole('option');
		// The favorites group (EUR, USD — ticker ascending) leads the list
		// under its header; the first active row (CHF) follows. The seed ships
		// most rows inactive — the basic setup enables six currencies.
		await expect(opts.length).toBeGreaterThan(5);
		await expect(opts[0]).toHaveTextContent('EUR');
		await expect(opts[1]).toHaveTextContent('USD');
		await expect(opts[2]).toHaveTextContent('CHF');
		// The header row itself is not an option. Retried through waitFor — the

		// menu pops in with a 140ms animation from opacity 0.
		await waitFor(() => expect(canvas.getByText('Favorites')).toBeVisible());
	}}
>
	{#snippet template(args)}
		<div class="money-story-frame">
			<MoneyInput label={args.label} placeholder="0" />
		</div>
	{/snippet}
</Story>

<Story
	name="FilterNarrows"
	args={{ label: 'Budget' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const currencyButton = canvas.getByRole('button', { name: 'Select currency' });
		await currencyButton.click();
		const filterInput = canvas.getByPlaceholderText('Filter currencies…');
		await filterInput.focus();
		// Filter by name fragment — only the Yen survives.
		await userEvent.type(filterInput, 'yen');
		const opts = canvas.getAllByRole('option');
		await expect(opts).toHaveLength(1);
		await expect(opts[0]).toHaveTextContent('JPY');
	}}
>
	{#snippet template(args)}
		<div class="money-story-frame">
			<MoneyInput label={args.label} placeholder="0" />
		</div>
	{/snippet}
</Story>

<Story
	name="InactiveStaysWhileCurrent"
	args={{ label: 'Budget', value: { value: '10', currency: 'FRF' } }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Override the store before the first interaction: FRF only exists as
		// an inactive row here (this override adds it). The stored
		// value stays committed on the button (the row carries no symbol, so
		// the bare code shows).
		seedCurrencies(rowsWithInactive);
		await expect(canvas.getByText('FRF')).toBeVisible();
		const currencyButton = canvas.getByRole('button', { name: 'Select currency' });
		await currencyButton.click();
		// The inactive row surfaces as a flagged option while it is current…
		// The menu pops in with a 140ms animation from opacity 0 — retry the
		// visibility check so it runs after the first painted frame (workflow
		// doc → Testing strategy → retry with waitFor).
		await waitFor(() => expect(canvas.getByText('Inactive')).toBeVisible());
		// …and choosing an active row locks it out again.
		const opts = canvas.getAllByRole('option');
		const eur = opts.find((o) => o.textContent?.includes('EUR'));
		await expect(eur).toBeDefined();
		await eur!.click();
		await expect(canvas.getByText('EUR')).toBeVisible();

		await expect(canvas.queryByText('Inactive')).toBeNull();
	}}
>
	{#snippet template(args)}
		<div class="money-story-frame">
			<MoneyInput label={args.label} placeholder="0" value={args.value} />
		</div>
	{/snippet}
</Story>

<Story
	name="EmptyStoreDegradesToCurrent"
	args={{ label: 'Budget', value: { value: '10', currency: 'USD' } }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Override the store to the failed-fetch state: the row set is empty,
		// so the picker degrades to the current ticker as the only option.
		seedCurrencies([]);
		const currencyButton = canvas.getByRole('button', { name: 'Select currency' });
		await currencyButton.click();
		// A failed fetch leaves the store empty — the picker degrades to the
		// current ticker as the only option.
		const opts = canvas.getAllByRole('option');
		await expect(opts).toHaveLength(1);
		await expect(opts[0]).toHaveTextContent('USD');
	}}
>
	{#snippet template(args)}
		<div class="money-story-frame">
			<MoneyInput label={args.label} placeholder="0" value={args.value} />
		</div>
	{/snippet}
</Story>

<style>
	.money-story-frame {
		display: block;
		width: 100%;
		max-width: 420px;
		margin: 24px auto;
		padding: 24px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: var(--sh-1);
		min-height: 120px;
	}
</style>
