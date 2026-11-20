<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import StatsCard from './StatsCard.svelte';
	import type { Stats } from '$lib/assistant/tool-call-helpers.js';

	const { Story } = defineMeta({
		title: 'Components/Features/Chat/StatsCard',
		component: StatsCard,
		tags: ['autodocs']
	});

	const moneyBag: Stats = {
		aggregate: 'sum',
		field: 'revenue',
		value: { USD: '184250.00', EUR: '42980.00' },
		count: 3
	};

	const scalarCount: Stats = {
		aggregate: 'count',
		value: 42,
		count: null
	};

	const emptySet: Stats = {
		aggregate: 'max',
		field: 'level',
		value: null,
		count: 0
	};
</script>

<script lang="ts">
	// Wait long enough for the first reactive render to settle — the card is
	// purely presentational, so no fetch settling is needed.
	const settle = (ms = 30): Promise<void> => new Promise((r) => setTimeout(r, ms));
</script>

<Story
	name="MoneyBag"
	play={async ({ canvasElement }) => {
		// A money aggregate returns the per-currency bag — one tile per
		// currency, formatted through the shared Money display.
		await settle();
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Revenue')).toBeVisible();
		await expect(canvas.getByText('sum · 3 documents')).toBeVisible();
		await expect(canvas.getByText('$ 184,250.00')).toBeVisible();
		await expect(canvas.getByText('€ 42,980.00')).toBeVisible();
		await expect(canvas.getByText('USD')).toBeVisible();
		await expect(canvas.getByText('EUR')).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="width: 320px; padding: 12px; background: var(--bg, var(--surface));">
			<StatsCard stats={moneyBag} />
		</div>
	{/snippet}
</Story>

<Story
	name="ScalarCount"
	play={async ({ canvasElement }) => {
		// A count run carries no field — the headline names the documents and
		// the value renders as a formatted number.
		await settle();
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Matching documents')).toBeVisible();
		await expect(canvas.getByText('count')).toBeVisible();
		await expect(canvas.getByText('42')).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="width: 320px; padding: 12px; background: var(--bg, var(--surface));">
			<StatsCard stats={scalarCount} />
		</div>
	{/snippet}
</Story>

<Story
	name="EmptySet"
	play={async ({ canvasElement }) => {
		// An empty set renders one blank tile with the zero-match note.
		await settle();
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Level')).toBeVisible();
		await expect(canvas.getByText('—')).toBeVisible();
		await expect(canvas.getByText('no matching documents')).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="width: 320px; padding: 12px; background: var(--bg, var(--surface));">
			<StatsCard stats={emptySet} />
		</div>
	{/snippet}
</Story>
