<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import ErrorFallback from './ErrorFallback.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Surfaces/ErrorFallback',
		component: ErrorFallback,
		tags: ['autodocs'],
		args: {
			onretry: () => {}
		}
	});
</script>

<script lang="ts">
	import { expect, within } from 'storybook/test';
	import * as m from '$lib/paraglide/messages';
</script>

<Story
	name="PageLevel"
	args={{
		error: new Error('Cannot read properties of undefined (reading "value")')
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText(m.errors_500_title())).toBeVisible();
		await expect(
			canvas.getByText('Cannot read properties of undefined (reading "value")')
		).toBeVisible();
		await expect(canvas.getByRole('button', { name: m.common_retry() })).toBeEnabled();
		await expect(canvas.getByRole('button', { name: m.common_back_to_dashboard() })).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div style="min-height: 400px; display: flex; align-items: stretch;">
			<ErrorFallback error={args.error} level="page" onretry={() => {}} />
		</div>
	{/snippet}
</Story>

<Story name="AppLevel">
	{#snippet template(args)}
		<div style="height: 500px; display: flex; align-items: stretch;">
			<ErrorFallback error={args.error} level="app" onretry={() => {}} />
		</div>
	{/snippet}
</Story>

<Story name="WithoutDetail">
	{#snippet template()}
		<div style="min-height: 400px; display: flex; align-items: stretch;">
			<ErrorFallback level="page" onretry={() => {}} />
		</div>
	{/snippet}
</Story>
