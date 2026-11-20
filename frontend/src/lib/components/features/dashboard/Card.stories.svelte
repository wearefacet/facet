<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, userEvent, fn } from 'storybook/test';
	import Card from './Card.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Dashboard/Card',
		component: Card,
		tags: ['autodocs'],
		argTypes: {
			variant: {
				control: 'select',
				options: ['danger', 'warning', 'notice']
			}
		},
		args: {
			title: 'Danger zone',
			description:
				'Deleting the doctype orphans every record and its children. This cannot be undone.',
			variant: 'danger',
			actionLabel: 'Delete doctype',
			onaction: fn()
		}
	});
</script>

<Story
	name="Danger"
	args={{ variant: 'danger' }}
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Danger zone')).toBeVisible();
		await expect(canvas.getByText(/orphans every record/)).toBeVisible();
		await userEvent.click(canvas.getByRole('button', { name: 'Delete doctype' }));
		await expect(args.onaction).toHaveBeenCalledOnce();
	}}
/>

<Story
	name="Warning"
	args={{
		variant: 'warning',
		title: 'Unsaved changes',
		description: 'You have unsaved changes that will be lost if you navigate away.',
		actionLabel: 'Review changes'
	}}
/>

<Story
	name="Notice"
	args={{
		variant: 'notice',
		title: 'Information',
		description:
			'This doctype is referenced by 3 other doctypes. Changes to its fields may affect dependent schemas.'
	}}
/>

<Story
	name="NoAction"
	args={{
		variant: 'notice',
		title: 'Read-only',
		description: 'This definition is inherited from a parent schema and cannot be modified here.',
		actionLabel: undefined
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.queryByRole('button')).toBeNull();
	}}
/>
