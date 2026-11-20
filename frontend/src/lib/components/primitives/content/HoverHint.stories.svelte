<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, userEvent, waitFor, within } from 'storybook/test';
	import HoverHint from './HoverHint.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Content/HoverHint',
		component: HoverHint,
		tags: ['autodocs']
	});
</script>

<Story
	name="WithText"
	args={{ text: 'A bounded-context namespace that groups doctypes.' }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const trigger = canvas.getByRole('button', { name: 'Description' });
		await expect(trigger).toBeInTheDocument();
		// The hint content is portalled to document.body (Bits UI Tooltip);
		// hovering reveals it next to the trigger.
		await userEvent.hover(trigger);
		const docBody = within(document.body);
		await waitFor(() => {
			const tip = docBody.getByText(args.text as string);
			expect(tip).toBeVisible();
		});
	}}
/>

<Story
	name="CustomLabel"
	args={{
		text: 'Permissions on this doctype prefix-match its child doctypes.',
		label: 'crm.Deal description'
	}}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const trigger = canvas.getByRole('button', { name: args.label as string });
		await expect(trigger).toBeInTheDocument();
	}}
/>

<Story
	name="EmptyRendersNothing"
	args={{ text: '' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.queryByRole('button')).toBeNull();
	}}
/>
