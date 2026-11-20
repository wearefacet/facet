<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import NewDomainDialog from './NewDomainDialog.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Dashboard/NewDomainDialog',
		component: NewDomainDialog,
		tags: ['autodocs'],
		argTypes: {
			// The create flow is a play-internal spy concern.
			oncreate: { table: { disable: true } }
		}
	});

	// Stories run sequentially in one iframe; each play resets the shared spy.
	let createCalls: { name: string; label?: string }[] = [];

	async function createSpy(input: { name: string; label?: string }): Promise<string | null> {
		createCalls.push(input);
		return null;
	}

	function resetSpy() {
		createCalls = [];
	}
</script>

<script lang="ts">
	import { expect, within, userEvent, waitFor } from 'storybook/test';

	// Shared open state, bound to every template's dialog. A `bind:open` on a
	// `$bindable` prop is what mounts the Bits UI portal.
	let open = $state(false);
</script>

<!--
	The dialog portals into `document.body`, so the play functions query
	`within(document.body)`. `oncreate` is injected — no network call runs in
	stories. A module-level `open` state drives the Bits UI portal (a plain
	`args.open` render does not mount it), and every play closes the dialog at
	the end so later stories see a single dialog in the portal.
-->

<Story
	name="InfersIdFromLabel"
	play={async () => {
		resetSpy();
		open = true;
		const body = within(document.body);
		await waitFor(() => expect(body.getByLabelText('Label')).toBeVisible());

		const labelInput = body.getByLabelText('Label');
		await userEvent.type(labelInput, 'My Domain');

		const idInput = body.getByLabelText('Domain id');
		await expect(idInput).toHaveValue('my-domain');

		await userEvent.click(body.getByRole('button', { name: 'Create draft' }));
		await waitFor(() => expect(createCalls).toEqual([{ name: 'my-domain', label: 'My Domain' }]));
		// Success closes the dialog.
		await waitFor(() => expect(body.queryByLabelText('Domain id')).toBeNull());
	}}
>
	{#snippet template()}
		<div style="position: relative; width: 100%; min-height: 320px;">
			<NewDomainDialog bind:open oncreate={createSpy} />
		</div>
	{/snippet}
</Story>

<Story
	name="ManualIdStopsInference"
	play={async () => {
		resetSpy();
		open = true;
		const body = within(document.body);
		await waitFor(() => expect(body.getByLabelText('Label')).toBeVisible());

		const labelInput = body.getByLabelText('Label');
		await userEvent.type(labelInput, 'My Domain');
		const idInput = body.getByLabelText('Domain id');
		await expect(idInput).toHaveValue('my-domain');

		// A hand-edited id stops following the label.
		await userEvent.clear(idInput);
		await userEvent.type(idInput, 'md');
		await userEvent.clear(labelInput);
		await userEvent.type(labelInput, 'Other', { delay: 30 });
		await waitFor(() => expect(idInput).toHaveValue('md'));

		// Clearing the id resumes inference on the next label keystroke.
		await userEvent.clear(idInput);
		await userEvent.type(labelInput, '!');
		await waitFor(() => expect(idInput).toHaveValue('other'));

		await userEvent.click(body.getByRole('button', { name: 'Cancel' }));
		await waitFor(() => expect(body.queryByLabelText('Domain id')).toBeNull());
	}}
>
	{#snippet template()}
		<div style="position: relative; width: 100%; min-height: 320px;">
			<NewDomainDialog bind:open oncreate={createSpy} />
		</div>
	{/snippet}
</Story>

<Story
	name="InvalidIdBlocksSubmit"
	play={async () => {
		resetSpy();
		open = true;
		const body = within(document.body);
		await waitFor(() => expect(body.getByLabelText('Label')).toBeVisible());

		const labelInput = body.getByLabelText('Label');
		// "3D Printing" infers "3d-printing" — the contract needs a leading letter.
		await userEvent.type(labelInput, '3D Printing');

		const idInput = body.getByLabelText('Domain id');
		await expect(idInput).toHaveValue('3d-printing');
		await expect(
			body.getByText('Must be lowercase alphanumeric (a-z, 0-9, -) and start with a letter.')
		).toBeVisible();
		await expect(body.getByRole('button', { name: 'Create draft' })).toBeDisabled();
		await expect(createCalls).toEqual([]);

		await userEvent.click(body.getByRole('button', { name: 'Cancel' }));
		await waitFor(() => expect(body.queryByLabelText('Domain id')).toBeNull());
	}}
>
	{#snippet template()}
		<div style="position: relative; width: 100%; min-height: 320px;">
			<NewDomainDialog bind:open oncreate={createSpy} />
		</div>
	{/snippet}
</Story>

<Story
	name="EmptyLabelSubmitsIdOnly"
	play={async () => {
		resetSpy();
		open = true;
		const body = within(document.body);
		await waitFor(() => expect(body.getByLabelText('Label')).toBeVisible());

		const idInput = body.getByLabelText('Domain id');
		await userEvent.type(idInput, 'orders', { delay: 30 });

		await userEvent.click(body.getByRole('button', { name: 'Create draft' }));
		await waitFor(() => expect(createCalls).toEqual([{ name: 'orders' }]));
		await waitFor(() => expect(body.queryByLabelText('Domain id')).toBeNull());
	}}
>
	{#snippet template()}
		<div style="position: relative; width: 100%; min-height: 320px;">
			<NewDomainDialog bind:open oncreate={createSpy} />
		</div>
	{/snippet}
</Story>
