<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, fn, userEvent, waitFor, within } from 'storybook/test';
	import RbacScopeSelect from './RbacScopeSelect.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Admin/RbacScopeSelect',
		component: RbacScopeSelect,
		tags: ['autodocs'],
		argTypes: {
			options: { control: 'object' }
		}
	});

	// Two named scopes as a doctype would declare them. The trigger shows
	// the option label verbatim for a single custom selection.
	const OPTIONS = [
		{ value: '$self', label: '$self — own records' },
		{ value: '$open_requests', label: '$open_requests — awaiting action' }
	];

	/** Wait long enough for the portalled dropdown to settle between picks. */
	const sleep = (ms: number): Promise<void> => new Promise((r) => setTimeout(r, ms));
</script>

<!--
	B-194: the picker is a Bits UI multi-select whose dropdown portals into
	document.body, so the plays query options there (the FilterBar story
	pattern). The trigger renders a plain button; the play opens it once and
	picks in sequence — the menu stays open between picks.
-->

<!-- B-194: a custom-scope click while "All" is selected drops the sentinel
	instead of silently refusing the click; multi-select continues, "None"
	still clears, and clicking "All" over custom scopes still collapses. -->
<Story
	name="CustomClickWhileAllDropsSentinel"
	play={async ({ canvasElement, args }) => {
		const canvas = within(canvasElement);
		const body = within(document.body);
		// The picker starts on the "All" sentinel.
		const trigger = canvas.getByRole('button', { name: 'All' });
		await userEvent.click(trigger);
		await waitFor(() => expect(body.getByRole('option', { name: /\$self/ })).toBeVisible());

		// A custom-scope click while All is on: the sentinel drops and the
		// click lands — the trigger shows the clicked scope.
		await userEvent.click(body.getByRole('option', { name: /\$self/ }));
		await sleep(40);
		await waitFor(() => expect(args.onchange).toHaveBeenCalledWith(['$self']));
		await expect(canvas.getByRole('button', { name: '$self — own records' })).toBeVisible();

		// Multi-select still works: a second scope shows the count.
		await userEvent.click(body.getByRole('option', { name: /\$open_requests/ }));
		await sleep(40);
		await waitFor(() => expect(args.onchange).toHaveBeenCalledWith(['$self', '$open_requests']));
		await expect(canvas.getByRole('button', { name: '2 scopes' })).toBeVisible();

		// "None" still clears everything.
		await userEvent.click(body.getByRole('option', { name: 'None' }));
		await sleep(40);
		await waitFor(() => expect(args.onchange).toHaveBeenCalledWith([]));
		await expect(canvas.getByRole('button', { name: 'None' })).toBeVisible();

		// Picking a custom scope, then "All", still collapses to the sentinel.
		await userEvent.click(body.getByRole('option', { name: /\$open_requests/ }));
		await sleep(40);
		await waitFor(() => expect(args.onchange).toHaveBeenCalledWith(['$open_requests']));
		await userEvent.click(body.getByRole('option', { name: 'All' }));
		await sleep(40);
		await waitFor(() => expect(args.onchange).toHaveBeenCalledWith(['$all']));
		await expect(canvas.getByRole('button', { name: 'All' })).toBeVisible();

		// Close the dropdown before the story ends: the a11y scan runs on the
		// final DOM, and the open listbox carries bits-ui's known open-state
		// ARIA findings (aria-activedescendant on the button trigger, the
		// unnamed listbox). The closed state is what ships statically.
		await userEvent.keyboard('{Escape}');
		await sleep(40);
	}}
	args={{
		options: OPTIONS,
		selected: ['$all'],
		onchange: fn()
	}}
/>
