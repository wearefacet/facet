<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import Duration from './Duration.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Data/Duration',
		component: Duration,
		tags: ['autodocs'],
		argTypes: {
			value: { control: 'number' }
		}
	});
</script>

<Story
	name="Default"
	args={{ value: 184504 }}
	play={async ({ canvasElement }) => {
		// All four segments render, separated by single spaces.
		await expect(within(canvasElement).getByText('2d 3h 15m 4s')).toBeVisible();
	}}
/>

<Story
	name="HoursMinutesSeconds"
	args={{ value: 9034 }}
	play={async ({ canvasElement }) => {
		await expect(within(canvasElement).getByText('2h 30m 34s')).toBeVisible();
	}}
/>

<Story
	name="MinutesSeconds"
	args={{ value: 95 }}
	play={async ({ canvasElement }) => {
		await expect(within(canvasElement).getByText('1m 35s')).toBeVisible();
	}}
/>

<Story
	name="WholeHours"
	args={{ value: 3600 }}
	play={async ({ canvasElement }) => {
		// Zero segments drop off both ends — only '1h' remains.
		await expect(within(canvasElement).getByText('1h')).toBeVisible();
	}}
/>

<Story
	name="SecondsOnly"
	args={{ value: 45 }}
	play={async ({ canvasElement }) => {
		await expect(within(canvasElement).getByText('45s')).toBeVisible();
	}}
/>

<Story
	name="Zero"
	args={{ value: 0 }}
	play={async ({ canvasElement }) => {
		// Zero never renders blank.
		await expect(within(canvasElement).getByText('0s')).toBeVisible();
	}}
/>

<Story
	name="NegativeClampsToZero"
	args={{ value: -30 }}
	play={async ({ canvasElement }) => {
		// A negative count reads as zero, never as a negative duration.
		await expect(within(canvasElement).getByText('0s')).toBeVisible();
	}}
/>

<Story
	name="FractionalFloors"
	args={{ value: 3661.9 }}
	play={async ({ canvasElement }) => {
		// Sub-second fractions floor to whole seconds.
		await expect(within(canvasElement).getByText('1h 1m 1s')).toBeVisible();
	}}
/>
