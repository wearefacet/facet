<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, userEvent, within } from 'storybook/test';
	import PreviewBanner from './PreviewBanner.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Surfaces/PreviewBanner',
		component: PreviewBanner,
		tags: ['autodocs']
	});

	// Exit spy — one slot, reset at the top of the play.
	let exitCalled = false;
	const onexit = () => {
		exitCalled = true;
	};
</script>

<Story
	name="Default"
	args={{ draftId: 'hr.Q8ZK4M2P' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// No label prop — the banner falls back to the raw draft id.
		await expect(canvas.getByText('Previewing draft hr.Q8ZK4M2P')).toBeVisible();
		await expect(canvas.getByRole('status')).toBeVisible();
		await expect(canvas.getByRole('button', { name: 'Exit preview' })).toBeVisible();
	}}
/>

<Story
	name="WithDomainLabel"
	args={{ draftId: 'hr.Q8ZK4M2P', label: 'Human Resources' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The banner names the draft by its display label, not the reference.
		await expect(canvas.getByText('Previewing draft Human Resources')).toBeVisible();
		await expect(canvas.queryByText('hr.Q8ZK4M2P')).toBeNull();
	}}
/>

<Story
	name="ExitCallsBack"
	args={{ draftId: 'hr.Q8ZK4M2P', onexit }}
	play={async ({ canvasElement }) => {
		exitCalled = false;
		const canvas = within(canvasElement);
		await userEvent.click(canvas.getByRole('button', { name: 'Exit preview' }));
		await expect(exitCalled).toBe(true);
	}}
/>
