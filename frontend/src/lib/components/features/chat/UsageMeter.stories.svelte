<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import UsageMeter from './UsageMeter.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Chat/UsageMeter',
		component: UsageMeter,
		tags: ['autodocs']
	});
</script>

<!--
	Unlimited accounts never mount this component — `ChatPanel` hides the
	meter when `budget` is `null`. The stories cover the finite-budget
	boundaries instead: a partial budget, an over-budget clamp, and the
	untouched window.
-->

<Story
	name="PartialBudget"
	args={{ used: 62000, budget: 100000, windowDays: 30 }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('62% of the 30-day budget used')).toBeVisible();
	}}
/>

<Story
	name="BudgetExhausted"
	args={{ used: 105000, budget: 100000, windowDays: 30 }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// Over-budget usage clamps at 100% — the bar never overflows.
		await expect(canvas.getByText('100% of the 30-day budget used')).toBeVisible();
	}}
/>

<Story
	name="WindowUntouched"
	args={{ used: 0, budget: 100000, windowDays: 30 }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('0% of the 30-day budget used')).toBeVisible();
	}}
/>

<Story
	name="MostlyEstimated"
	args={{ used: 62000, estimated: 40000, budget: 100000, windowDays: 30 }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('62% of the 30-day budget used')).toBeVisible();
		// 40000 / 62000 rounds to 65% — the hint names the estimate share.
		await expect(
			canvas.getByText('about 65% of that is an estimate, not a reported count')
		).toBeVisible();
	}}
/>

<Story
	name="ReportedOnly"
	args={{ used: 62000, estimated: 0, budget: 100000, windowDays: 30 }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// No estimate — the hint line stays absent.
		await expect(canvas.queryByText(/estimate/)).toBeNull();
	}}
/>
