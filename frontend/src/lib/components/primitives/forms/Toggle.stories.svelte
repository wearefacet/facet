<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, userEvent, fn } from 'storybook/test';
	import Toggle from './Toggle.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Forms/Toggle',
		component: Toggle,
		tags: ['autodocs'],
		args: {
			onchange: fn()
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});
</script>

<Story
	name="Off"
	args={{ label: 'Enable notifications' }}
	play={async ({ canvasElement, args: _args }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Enable notifications')).toBeVisible();
		const sw = canvas.getByRole('switch');
		await expect(sw).toHaveAttribute('aria-checked', 'false');
	}}
/>

<Story
	name="On"
	args={{ label: 'Enable notifications', checked: true }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByRole('switch')).toHaveAttribute('aria-checked', 'true');
	}}
/>

<Story
	name="Disabled"
	args={{ label: 'Feature flag', disabled: true }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		const sw = canvas.getByRole('switch');
		await expect(sw).toBeDisabled();
	}}
/>

<Story name="DisabledOn" args={{ label: 'Already active', disabled: true, checked: true }} />
<Story name="NoLabel" args={{ checked: true }} />

<Story
	name="TogglesOnClick"
	args={{ label: 'Toggle me' }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const sw = canvas.getByRole('switch');
		await expect(sw).toHaveAttribute('aria-checked', 'false');
		await userEvent.click(sw);
		await expect(sw).toHaveAttribute('aria-checked', 'true');
		await expect(args.onchange).toHaveBeenCalled();
	}}
/>
