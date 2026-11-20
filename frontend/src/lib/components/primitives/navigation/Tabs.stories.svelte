<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, fn, userEvent, within } from 'storybook/test';
	import Tabs from './Tabs.svelte';

	const onAdd = fn();

	const { Story } = defineMeta({
		title: 'Components/Primitives/Navigation/Tabs',
		component: Tabs,
		tags: ['autodocs'],
		argTypes: {
			active: { control: 'number', min: 0 }
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});
</script>

<Story
	name="Default"
	args={{
		tabs: [{ label: 'Details' }, { label: 'Activity' }, { label: 'Relations' }]
	}}
/>

<Story
	name="WithCounts"
	args={{
		tabs: [
			{ label: 'Open', count: 12 },
			{ label: 'Reconciled', count: 48 },
			{ label: 'Disputed', count: 3 }
		]
	}}
/>

<Story
	name="WithErrors"
	args={{
		tabs: [{ label: 'Valid' }, { label: 'Errors', error: true, count: 2 }, { label: 'Warnings' }]
	}}
/>

<Story
	name="SecondActive"
	args={{
		active: 1,
		tabs: [{ label: 'Details' }, { label: 'Activity', count: 7 }, { label: 'Relations' }]
	}}
/>

<!-- Snippet props cannot travel through `args` — the icon and trailing
	actions render inline via a template. -->
<Story
	name="WithIconAndTrailing"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		onAdd.mockClear();
		// Each tab carries its lead icon; the trailing action fires.
		await expect(canvas.getAllByRole('tab')).toHaveLength(2);
		await expect(canvas.getByRole('button', { name: 'Add view' })).toBeVisible();
		await userEvent.click(canvas.getByRole('button', { name: 'Add view' }));
		await expect(onAdd).toHaveBeenCalled();
	}}
>
	{#snippet template()}
		<Tabs tabs={[{ label: 'List' }, { label: 'Calendar' }]} onchange={fn()}>
			{#snippet icon(i: number)}
				<span data-testid="tab-icon-{i}">icon</span>
			{/snippet}
			{#snippet trailing()}
				<button onclick={onAdd}>Add view</button>
			{/snippet}
		</Tabs>
	{/snippet}
</Story>
