<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import ColorSwatch from './ColorSwatch.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Data/ColorSwatch',
		component: ColorSwatch,
		tags: ['autodocs'],
		argTypes: {
			value: { control: 'text' }
		}
	});
</script>

<Story
	name="PipelineStageColors"
	args={{ value: '#9E9E9E' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('#9E9E9E')).toBeVisible();
		await expect(canvas.getByText('#2196F3')).toBeVisible();
		await expect(canvas.getByText('#4CAF50')).toBeVisible();
	}}
>
	{#snippet template()}
		<div class="swatch-grid">
			<ColorSwatch value="#9E9E9E" />
			<ColorSwatch value="#2196F3" />
			<ColorSwatch value="#FF9800" />
			<ColorSwatch value="#F44336" />
			<ColorSwatch value="#4CAF50" />
			<ColorSwatch value="#607D8B" />
		</div>
	{/snippet}
</Story>

<Story name="ThreeDigitHex" args={{ value: '#abc' }}>
	{#snippet template(args)}
		<div class="story-frame">
			<ColorSwatch value={args.value} />
		</div>
	{/snippet}
</Story>

<Story name="SixDigitHex" args={{ value: '#4CAF50' }}>
	{#snippet template(args)}
		<div class="story-frame">
			<ColorSwatch value={args.value} />
		</div>
	{/snippet}
</Story>

<Story name="EightDigitHexWithAlpha" args={{ value: '#4CAF50AA' }}>
	{#snippet template(args)}
		<div class="story-frame">
			<ColorSwatch value={args.value} />
		</div>
	{/snippet}
</Story>

<Story name="RgbFunctional" args={{ value: 'rgb(255, 87, 34)' }}>
	{#snippet template(args)}
		<div class="story-frame">
			<ColorSwatch value={args.value} />
		</div>
	{/snippet}
</Story>

<Story name="HslFunctional" args={{ value: 'hsl(300, 100%, 50%)' }}>
	{#snippet template(args)}
		<div class="story-frame">
			<ColorSwatch value={args.value} />
		</div>
	{/snippet}
</Story>

<style>
	.story-frame {
		display: inline-flex;
		align-items: center;
		padding: 16px 20px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: var(--sh-1);
		min-height: 56px;
	}

	.swatch-grid {
		display: grid;
		grid-template-columns: repeat(3, minmax(0, 1fr));
		gap: 14px;
		padding: 24px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: var(--sh-1);
	}
</style>
