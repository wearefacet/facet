<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import NewApiKeyDialog from './NewApiKeyDialog.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Settings/NewApiKeyDialog',
		component: NewApiKeyDialog,
		tags: ['autodocs'],
		args: {
			open: true,
			roles: ['iam.Roles.viewer', 'iam.Roles.editor', 'iam.Roles.production_editor'],
			oncreate: async (_input) => null
		}
	});
</script>

<script lang="ts">
	import { expect, within, userEvent, waitFor, fn } from 'storybook/test';
	import type { CreateApiKeyInput } from '$lib/iam/apiKeys.js';

	// Shared open/role state for the reopen story: the dialog is controlled
	// through real bindings so the play can close it (a successful create) and
	// open it again — the path that used to leak the previous entry into the
	// fresh form.
	let reopenOpen = $state(true);
	let reopenRole = $state('iam.Roles.viewer');
	const reopenCreate = fn(async (_input: CreateApiKeyInput) => null);
</script>

<!--
	Bits UI `Dialog.Portal` mounts content into `document.body`, so the play
	functions query `within(document.body)`. The role picker is the project
	`Select` primitive (Bits UI combobox, non-searchable): the placeholder is
	an input attribute (`getByPlaceholder`), and the dropdown opens on the
	pointerdown the click performs. Every play closes the dialog at the end so
	later stories start with a clean portal.
-->

<Story
	name="DefaultCreateDisabledUntilNameAndRoleAreSet"
	args={{ open: true }}
	play={async () => {
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('New API key')).toBeVisible());

		// Nothing filled: the submit button must stay disabled.
		await expect(body.getByRole('button', { name: 'Create key' })).toBeDisabled();

		// Clean up so later stories see a single dialog in the portal.
		await userEvent.click(body.getByRole('button', { name: 'Cancel' }));
		await waitFor(() => {
			expect(body.queryByText('New API key')).toBeNull();
		});
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 480px;">
			<NewApiKeyDialog open={args.open} roles={args.roles} oncreate={args.oncreate} />
		</div>
	{/snippet}
</Story>

<Story
	name="ValidInputSubmitsAndCloses"
	args={{ open: true }}
	play={async () => {
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('New API key')).toBeVisible());

		const nameInput = body.getByPlaceholderText('e.g. CI pipeline');
		await userEvent.type(nameInput, 'CI pipeline');

		// Open the role picker and pick the first option.
		const picker = body.getByPlaceholderText('Pick the role this key acts as');
		await picker.focus();
		await waitFor(() => expect(body.getByRole('option', { name: 'Viewer' })).toBeVisible());
		await userEvent.click(body.getByRole('option', { name: 'Viewer' }));

		const createBtn = body.getByRole('button', { name: 'Create key' });
		await expect(createBtn).toBeEnabled();
		await userEvent.click(createBtn);

		// Success: the dialog closes (no oncreate error to render).
		await waitFor(() => {
			expect(body.queryByText('New API key')).toBeNull();
		});
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 480px;">
			<NewApiKeyDialog open={args.open} roles={args.roles} oncreate={args.oncreate} />
		</div>
	{/snippet}
</Story>

<Story
	name="PastExpiryShowsInlineErrorCreateStaysDisabled"
	args={{ open: true }}
	play={async () => {
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('New API key')).toBeVisible());

		await userEvent.type(body.getByPlaceholderText('e.g. CI pipeline'), 'CI pipeline');
		const picker = body.getByPlaceholderText('Pick the role this key acts as');
		await picker.focus();
		await waitFor(() => expect(body.getByRole('option', { name: 'Viewer' })).toBeVisible());
		await userEvent.click(body.getByRole('option', { name: 'Viewer' }));

		// DatetimePicker segments — type the wall-clock expiry (the runner's
		// timezone). 2020 is in the past in every zone, so the check is stable.
		await userEvent.type(body.getByLabelText('year'), '2020');
		await userEvent.type(body.getByLabelText('month'), '01');
		await userEvent.type(body.getByLabelText('day'), '01');
		await userEvent.type(body.getByLabelText('hour'), '10');
		await userEvent.type(body.getByLabelText('minute'), '00');

		await expect(body.getByText('The expiry must be in the future.')).toBeVisible();
		await expect(body.getByRole('button', { name: 'Create key' })).toBeDisabled();

		await userEvent.click(body.getByRole('button', { name: 'Cancel' }));
		await waitFor(() => {
			expect(body.queryByText('New API key')).toBeNull();
		});
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 480px;">
			<NewApiKeyDialog open={args.open} roles={args.roles} oncreate={args.oncreate} />
		</div>
	{/snippet}
</Story>

<Story
	name="BackendErrorSurfacesInline"
	args={{
		open: true,
		role: 'iam.Roles.viewer',
		oncreate: async () => 'Role is not assigned to the caller'
	}}
	play={async () => {
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('New API key')).toBeVisible());

		// The role arrives preselected via the bindable `role` prop — the
		// dropdown interaction is covered by ValidInputSubmitsAndCloses.
		await userEvent.type(body.getByPlaceholderText('e.g. CI pipeline'), 'CI pipeline');
		const createBtn = body.getByRole('button', { name: 'Create key' });
		await waitFor(() => expect(createBtn).toBeEnabled());
		await userEvent.click(createBtn);

		// The dialog stays open and the backend error renders in the alert box.
		await waitFor(
			() => {
				expect(body.getByText('New API key')).toBeVisible();
				expect(body.getByText('Role is not assigned to the caller')).toBeVisible();
			},
			{ timeout: 3000 }
		);

		await userEvent.click(body.getByRole('button', { name: 'Cancel' }));
		await waitFor(() => {
			expect(body.queryByText('New API key')).toBeNull();
		});
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 480px;">
			<NewApiKeyDialog
				open={args.open}
				roles={args.roles}
				role={args.role}
				oncreate={args.oncreate}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ReopenAfterASuccessfulCreateShowsAnEmptyForm"
	play={async () => {
		reopenCreate.mockClear();
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('New API key')).toBeVisible());

		await userEvent.type(body.getByPlaceholderText('e.g. CI pipeline'), 'CI pipeline');
		// The role arrives preselected via the bound `role` prop — the dropdown
		// interaction is covered by ValidInputSubmitsAndCloses.
		const createBtn = body.getByRole('button', { name: 'Create key' });
		await waitFor(() => expect(createBtn).toBeEnabled());
		await userEvent.click(createBtn);

		// A successful create closes the dialog.
		await waitFor(() => expect(reopenOpen).toBe(false));

		// Reopen: the form must be empty again.
		reopenOpen = true;
		await waitFor(() => expect(body.getByPlaceholderText('e.g. CI pipeline')).toBeVisible());
		await expect(body.getByPlaceholderText('e.g. CI pipeline')).toHaveValue('');
	}}
>
	{#snippet template()}
		<div style="position: relative; width: 100%; min-height: 480px;">
			<NewApiKeyDialog
				bind:open={reopenOpen}
				roles={['iam.Roles.viewer']}
				bind:role={reopenRole}
				oncreate={reopenCreate}
			/>
		</div>
	{/snippet}
</Story>
