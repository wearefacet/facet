<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, userEvent, waitFor } from 'storybook/test';
	import RelativeTime from './RelativeTime.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Data/RelativeTime',
		component: RelativeTime,
		tags: ['autodocs'],
		argTypes: {
			date: { control: 'date' }
		}
	});
</script>

<Story
	name="JustNow"
	args={{ date: new Date().toISOString() }}
	play={async ({ canvasElement }) => {
		await expect(within(canvasElement).getByText('just now')).toBeVisible();
	}}
/>

<Story
	name="MinutesAgo"
	args={{ date: new Date(Date.now() - 5 * 60 * 1000).toISOString() }}
	play={async ({ canvasElement }) => {
		await expect(within(canvasElement).getByText('5m ago')).toBeVisible();
	}}
/>

<Story
	name="HoursAgo"
	args={{ date: new Date(Date.now() - 3 * 60 * 60 * 1000).toISOString() }}
	play={async ({ canvasElement }) => {
		await expect(within(canvasElement).getByText('3h ago')).toBeVisible();
	}}
/>

<Story
	name="DaysAgo"
	args={{ date: new Date(Date.now() - 2 * 24 * 60 * 60 * 1000).toISOString() }}
	play={async ({ canvasElement }) => {
		await expect(within(canvasElement).getByText('2d ago')).toBeVisible();
	}}
/>

<Story
	name="InOneHour"
	args={{ date: new Date(Date.now() + 1 * 60 * 60 * 1000).toISOString() }}
	play={async ({ canvasElement }) => {
		await expect(within(canvasElement).getByText('in 1h')).toBeVisible();
	}}
/>

<Story
	name="InThreeDays"
	args={{ date: new Date(Date.now() + 3 * 24 * 60 * 60 * 1000).toISOString() }}
	play={async ({ canvasElement }) => {
		await expect(within(canvasElement).getByText('in 3d')).toBeVisible();
	}}
/>

<Story
	name="TooltipShowsExactDatetime"
	args={{ date: new Date(Date.now() - 5 * 60 * 1000).toISOString() }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The relative label is visible and the trigger is a semantic `<time>`.
		const time = canvas.getByText('5m ago');
		await expect(time).toBeVisible();
		await expect(time.tagName).toBe('TIME');
		// Hovering reveals the exact datetime (portalled to document.body).
		await userEvent.hover(time);
		const docBody = within(document.body);
		await waitFor(() => {
			expect(docBody.getByText(/\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}/)).toBeVisible();
		});
	}}
/>

<Story
	name="NullDate"
	args={{ date: null as unknown as string }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// A null date renders a muted dash, never a `NaN`-derived label.
		await expect(canvas.getByText('—')).toBeVisible();
		await expect(canvas.queryByText(/NaNy ago/)).toBeNull();
	}}
/>
