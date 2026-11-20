<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import Money from './Money.svelte';

	// Currency rows come from the preview loader, which seeds the store
	// from the mock driver's `core.Currency` documents before every story —
	// the display stories render the real seed set (symbol, digits,
	// grouping) without an API.

	const { Story } = defineMeta({
		title: 'Components/Primitives/Data/Money',
		component: Money,
		tags: ['autodocs'],
		argTypes: {
			currency: {
				control: 'select',
				options: ['EUR', 'USD', 'GBP', 'JPY', 'IDR']
			},
			precision: {
				control: 'number'
			}
		}
	});
</script>

<Story
	name="DefaultEUR"
	args={{ amount: 12480.0 }}
	play={async ({ canvasElement }) => {
		await expect(within(canvasElement).getByText('€ 12,480.00')).toBeVisible();
	}}
/>

<Story
	name="USD"
	args={{ amount: 99.99, currency: 'USD' }}
	play={async ({ canvasElement }) => {
		await expect(within(canvasElement).getByText('$ 99.99')).toBeVisible();
	}}
/>

<Story
	name="GBP"
	args={{ amount: 50, currency: 'GBP' }}
	play={async ({ canvasElement }) => {
		await expect(within(canvasElement).getByText('£ 50.00')).toBeVisible();
	}}
/>

<Story
	name="LargeAmount"
	args={{ amount: 28900.0 }}
	play={async ({ canvasElement }) => {
		await expect(within(canvasElement).getByText('€ 28,900.00')).toBeVisible();
	}}
/>

<Story
	name="Zero"
	args={{ amount: 0 }}
	play={async ({ canvasElement }) => {
		await expect(within(canvasElement).getByText('€ 0.00')).toBeVisible();
	}}
/>

<Story
	name="WithCents"
	args={{ amount: 1044.2 }}
	play={async ({ canvasElement }) => {
		await expect(within(canvasElement).getByText('€ 1,044.20')).toBeVisible();
	}}
/>

<Story
	name="EstimateNoCents"
	args={{ amount: 2000000, precision: 0 }}
	play={async ({ canvasElement }) => {
		// Firmographic estimates drop cent precision so the figure does not
		// imply a false accuracy the source data does not carry.
		await expect(within(canvasElement).getByText('€ 2,000,000')).toBeVisible();
	}}
/>

<Story
	name="ZeroPrecisionUSD"
	args={{ amount: 15499.5, currency: 'USD', precision: 0 }}
	play={async ({ canvasElement }) => {
		await expect(within(canvasElement).getByText('$ 15,500')).toBeVisible();
	}}
/>

<Story
	name="RowDigitsYen"
	args={{ amount: 15499.5, currency: 'JPY' }}
	play={async ({ canvasElement }) => {
		// Without an explicit precision override, the stored currency row's
		// digits drive the display — the Yen seeds with 0 digits.
		await expect(within(canvasElement).getByText('¥ 15,500')).toBeVisible();
	}}
/>

<Story
	name="LakhsGroupingRupiah"
	args={{ amount: 1234567, currency: 'IDR' }}
	play={async ({ canvasElement }) => {
		// The Rupiah row declares the lakhs grouping — Indian digit groups.
		await expect(within(canvasElement).getByText('Rp 12,34,567.00')).toBeVisible();
	}}
/>

<Story
	name="UnknownTickerFallback"
	args={{ amount: 12480, currency: 'XYZ' }}
	play={async ({ canvasElement }) => {
		// A ticker the store lacks (deleted row, trimmed role grant) renders
		// with 2 digits and the bare ticker as label.
		await expect(within(canvasElement).getByText('XYZ 12,480.00')).toBeVisible();
	}}
/>
