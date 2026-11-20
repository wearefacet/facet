<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, userEvent, within } from 'storybook/test';
	import TagPicker from './TagPicker.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Forms/TagPicker',
		component: TagPicker,
		tags: ['autodocs'],
		args: {
			options: [
				{ value: 'full_name', label: 'full_name' },
				{ value: 'email', label: 'email' },
				{ value: 'phone', label: 'phone' }
			],
			selected: ['email'],
			disabled: false
		}
	});

	// Captures the last emitted selection for assertion. Cleared before each
	// story run so cross-story leakage can't produce false positives.
	let lastToggle: string[] | undefined = undefined;
</script>

<Story
	name="Default"
	args={{
		ontoggle: (next: string[]) => {
			lastToggle = next;
		}
	}}
	play={async ({ canvasElement }) => {
		lastToggle = undefined;
		const canvas = within(canvasElement);
		// 'email' is selected (pressed) initially.
		const email = canvas.getByRole('button', { name: 'email' });
		await expect(email).toHaveAttribute('aria-pressed', 'true');

		// Clicking 'full_name' adds it to the selection.
		await userEvent.click(canvas.getByRole('button', { name: 'full_name' }));
		await expect(lastToggle).toEqual(['email', 'full_name']);
	}}
/>

<Story
	name="Disabled"
	args={{
		disabled: true,
		selected: ['email'],
		ontoggle: (next: string[]) => {
			lastToggle = next;
		}
	}}
	play={async ({ canvasElement }) => {
		lastToggle = undefined;
		const canvas = within(canvasElement);
		// Disabled tags are not interactive — the toggle never fires.
		await userEvent.click(canvas.getByRole('button', { name: 'email' }));
		await expect(lastToggle).toBeUndefined();
	}}
/>

<Story
	name="Empty"
	args={{
		options: [],
		selected: []
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('No options available.')).toBeInTheDocument();
	}}
/>
