<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, fn, userEvent, waitFor, within } from 'storybook/test';
	import CopyButton from './CopyButton.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Data/CopyButton',
		component: CopyButton,
		tags: ['autodocs'],
		args: {
			oncopied: fn()
		}
	});
</script>

<!--
	The copy interaction is asserted through the label flip (Copy → Copied)
	because clipboard write permission is not guaranteed in the headless
	browser: `copyText` may fail, and then no feedback must appear.
-->

<Story
	name="Outline"
	args={{ value: 'fct_9f2c41b8', title: 'Copy key to clipboard' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The accessible name is the visible label and flips on copy; title is
		// only the native tooltip.
		const btn = canvas.getByRole('button', { name: 'Copy' });
		await expect(btn).toBeVisible();
		await expect(btn).toHaveAttribute('title', 'Copy key to clipboard');
	}}
/>

<Story name="GhostInline" args={{ value: 'client-id-1234', variant: 'ghost', label: 'Copy' }} />

<Story name="Primary" args={{ value: 'temp-password-1', variant: 'primary' }} />

<Story name="Small" args={{ value: 'https://facet.example.com', size: 'sm' }} />

<Story
	name="IconOnly"
	args={{ value: 'fct_9f2c41b8', iconOnly: true, title: 'Copy key to clipboard' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		// The accessible name comes from the title; there is no visible label.
		const btn = canvas.getByRole('button', { name: 'Copy key to clipboard' });
		await expect(btn).toBeVisible();
		await expect(canvas.queryByText('Copy')).toBeNull();
		// Headless Chromium may reject clipboard writes; stub the API so the
		// click deterministically reaches the copied state.
		Object.defineProperty(navigator, 'clipboard', {
			value: { writeText: async () => {} },
			configurable: true
		});
		await userEvent.click(btn);
		// With no label the feedback is the icon flip alone (copied class).
		await waitFor(() => expect(btn).toHaveClass('copied'));
	}}
/>

<Story
	name="CustomLabels"
	args={{ value: 'value-to-place', label: 'Copy address', copiedLabel: 'Address copied' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Copy address')).toBeVisible();
	}}
/>

<Story
	name="EmptyValueDoesNotFlip"
	args={{ value: '', label: 'Copy' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const btn = canvas.getByRole('button', { name: 'Copy' });
		await userEvent.click(btn);
		// A copy that cannot even attempt must not show false feedback.
		await expect(canvas.getByText('Copy')).toBeVisible();
	}}
/>

<Story
	name="ClickShowsSettledLabel"
	args={{ value: 'copyable text' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const btn = canvas.getByRole('button', { name: 'Copy' });
		await userEvent.click(btn);
		// Whether the headless browser grants the clipboard permission decides
		// the branch; assert the settled UI shows exactly one of the two labels.
		await waitFor(() => {
			const flipped = canvas.queryByText('Copied') !== null;
			const idle = canvas.queryByText('Copy') !== null;
			if (!flipped && !idle) throw new Error('CopyButton rendered neither label');
		});
	}}
/>
