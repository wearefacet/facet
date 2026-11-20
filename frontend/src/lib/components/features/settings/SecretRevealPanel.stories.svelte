<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import SecretRevealPanel from './SecretRevealPanel.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Settings/SecretRevealPanel',
		component: SecretRevealPanel,
		tags: ['autodocs']
	});
</script>

<Story
	name="Default"
	args={{ secret: 'fct_9f2c41b8d7e60a35c1' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('fct_9f2c41b8d7e60a35c1')).toBeVisible();
		// The one-time warning is the contract of the surface.
		await expect(
			canvas.getByText('Shown once. Store it now — Facet keeps only its hash.')
		).toBeVisible();
		// Copy affordance present (label + optional title overlap; query by text).
		await expect(canvas.getByText('Copy')).toBeVisible();
	}}
/>

<Story name="WithTitle" args={{ secret: 'fct_abcdef123456', title: 'API key' }} />

<Story name="WithTrailingAction" args={{ secret: 'temp-password-77' }}>
	{#snippet template(args)}
		<SecretRevealPanel secret={args.secret}>
			<button type="button" class="story-done">I stored it</button>
		</SecretRevealPanel>
	{/snippet}
</Story>

<style>
	.story-done {
		padding: 6px 14px;
		border-radius: var(--r);
		border: 1px solid var(--accent);
		background: var(--accent);
		color: var(--on-accent);
		font-size: 12.5px;
		font-weight: 600;
		cursor: pointer;
	}
</style>
