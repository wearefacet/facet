<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, fn, userEvent, waitFor, within } from 'storybook/test';
	import DropdownMenu from './DropdownMenu.svelte';
	import { MoreVertical } from '@lucide/svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Actions/DropdownMenu',
		component: DropdownMenu,
		tags: ['autodocs']
	});

	/** Small settle budget for the portalled menu content. */
	const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));
	/** Spy for the ClosesOnSelect story (cleared inside the play function). */
	const spyEdit = fn();
</script>

<Story
	name="Default"
	args={{
		label: 'Actions',
		items: [
			{ label: 'Edit', onclick: fn() },
			{ label: 'Duplicate', onclick: fn() },
			{ label: 'Delete', onclick: fn() }
		]
	}}
/>

<Story
	name="WithSeparator"
	args={{
		label: 'More',
		items: [
			{ label: 'Approve', onclick: fn() },
			{ label: 'Reject', onclick: fn() },
			{ label: '', separator: true },
			{ label: 'Archive', onclick: fn() },
			{ label: 'Delete', onclick: fn() }
		]
	}}
/>

<Story
	name="DisabledItem"
	args={{
		label: 'Manage',
		items: [
			{ label: 'Open', onclick: fn() },
			{ label: 'Edit', onclick: fn() },
			{ label: 'Archive', disabled: true, onclick: fn() }
		]
	}}
/>

<Story
	name="AlignEnd"
	args={{
		label: 'Right aligned',
		align: 'end',
		items: [
			{ label: 'Profile', onclick: fn() },
			{ label: 'Settings', onclick: fn() },
			{ label: 'Log out', onclick: fn() }
		]
	}}
/>

<Story
	name="IconTrigger"
	args={{
		label: 'Options',
		trigger: 'icon',
		align: 'end',
		items: [
			{ label: 'Rename', onclick: fn() },
			{ label: 'Export', onclick: fn() },
			{ label: 'Delete', onclick: fn(), variant: 'danger' }
		]
	}}
>
	<MoreVertical size={15} strokeWidth={2} aria-hidden="true" />
</Story>

<Story
	name="ClosesOnSelect"
	args={{
		label: 'Actions',
		items: [{ label: 'Edit', onclick: spyEdit }]
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		spyEdit.mockClear();
		// Open the menu — the content portals to document.body.
		await userEvent.click(canvas.getByRole('button', { name: 'Actions' }));
		await sleep(60);
		const body = within(document.body);
		// Picking an item runs its handler…
		await userEvent.click(body.getByRole('menuitem', { name: 'Edit' }));
		await expect(spyEdit).toHaveBeenCalledTimes(1);
		// …and closes the menu, so the trigger stays usable without Escape.
		await waitFor(() => {
			expect(body.queryByRole('menuitem', { name: 'Edit' })).toBeNull();
		});
	}}
/>
