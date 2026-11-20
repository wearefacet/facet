<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import NewRoleDialog from './NewRoleDialog.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Admin/NewRoleDialog',
		component: NewRoleDialog,
		tags: ['autodocs'],
		args: {
			open: true,
			oncreate: async (_name: string, _desc: string, _level: number) => null
		}
	});
</script>

<script lang="ts">
	import { expect, within, userEvent, waitFor, fn } from 'storybook/test';

	// Shared mock that rejects with a validation-shaped error — used by the
	// "Duplicate name surfaces structured validation error" story to lock in
	// that the dialog renders the field-scoped detail line, not just the
	// bare "Document validation failed" headline.
	const duplicateReject = async () => ({
		message: 'Document validation failed',
		details: ["name — must be unique, but value 'test' already exists"]
	});

	// Mock that resolves successfully and records the payload — used by the
	// "Create submits the level in the callback payload" story to lock in that
	// the callback receives `level` as a number.
	const createResolve = fn(async (_name: string, _desc: string, _level: number) => null);

	// Shared open state for the reopen story: the dialog is controlled through a
	// real binding so the play can close it (a successful create) and open it
	// again — the path that used to leak the previous entry into the fresh form.
	let reopenOpen = $state(true);
	const reopenCreate = fn(async (_name: string, _desc: string, _level: number) => null);
</script>

<!--
	Bits UI `Dialog.Portal` mounts content into `document.body`, so the `play`
	functions query `within(document.body)` rather than the canvas root. The dialog
	is opened via a `Dialog.Root` controlled by the `open` arg.
-->

<Story
	name="Default — open with visible Create button text"
	args={{ open: true }}
	play={async ({ canvasElement: _canvasElement }) => {
		await waitFor(() => {
			expect(within(document.body).getByRole('heading', { name: 'New role' })).toBeVisible();
		});

		// Regression guard for the "no text" bug: the create button's accessible
		// name must be the visible label "Create role" (not the empty string that
		// gold-on-gold text used to produce). The accessible name derives from the
		// rendered text content, so an invisible label would surface as an empty
		// name and `getByRole('button', { name: 'Create role' })` would throw.
		const createBtn = within(document.body).getByRole('button', { name: 'Create role' });
		await expect(createBtn).toBeVisible();
		await expect(createBtn).toBeDisabled();

		// The required level field must be present; empty, it keeps Create
		// disabled (the field is required, so an untouched dialog cannot submit).
		const levelInput = within(document.body).getByLabelText('Level');
		await expect(levelInput).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 400px;">
			<NewRoleDialog open={args.open} oncreate={args.oncreate} />
		</div>
	{/snippet}
</Story>

<Story
	name="Invalid name shows inline hint, Create stays disabled"
	args={{ open: true }}
	play={async ({ canvasElement: _canvasElement }) => {
		const body = within(document.body);
		await waitFor(() => expect(body.getByPlaceholderText('e.g. content_editor')).toBeVisible());

		const input = body.getByPlaceholderText('e.g. content_editor');
		await userEvent.type(input, 'Bad Name With Spaces');
		await expect(
			body.getByText(/Must start with a letter; only lowercase letters, digits, and underscores/)
		).toBeVisible();
		// The Create button stays disabled until the name matches the pattern.
		const createBtn = body.getByRole('button', { name: 'Create role' });
		await expect(createBtn).toBeDisabled();
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 400px;">
			<NewRoleDialog open={args.open} oncreate={args.oncreate} />
		</div>
	{/snippet}
</Story>

<Story
	name="Duplicate name surfaces structured validation error"
	args={{ open: true, oncreate: duplicateReject }}
	play={async ({ canvasElement: _canvasElement }) => {
		const body = within(document.body);
		await waitFor(() => expect(body.getByPlaceholderText('e.g. content_editor')).toBeVisible());

		const input = body.getByPlaceholderText('e.g. content_editor');
		await userEvent.type(input, 'test');
		await userEvent.type(body.getByLabelText('Level'), '50');
		await userEvent.click(body.getByRole('button', { name: 'Create role' }));

		// The headline AND the field-scoped detail line must both be visible
		// (regression guard for the "unhelpful error: Document validation failed only").
		await waitFor(() => {
			expect(body.getByText('Document validation failed')).toBeVisible();
		});
		await expect(
			body.getByText("name — must be unique, but value 'test' already exists")
		).toBeVisible();
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 400px;">
			<NewRoleDialog open={args.open} oncreate={args.oncreate} />
		</div>
	{/snippet}
</Story>

<Story
	name="Create submits the level in the callback payload"
	args={{ open: true, oncreate: createResolve }}
	play={async ({ canvasElement: _canvasElement, args }) => {
		createResolve.mockClear();
		const body = within(document.body);
		await waitFor(() => expect(body.getByPlaceholderText('e.g. content_editor')).toBeVisible());

		await userEvent.type(body.getByPlaceholderText('e.g. content_editor'), 'test');
		await userEvent.type(body.getByLabelText('Level'), '50');
		await userEvent.click(body.getByRole('button', { name: 'Create role' }));

		// The payload must carry `level` as a number, alongside the name and
		// the (optional, empty) description.
		await waitFor(() => {
			expect(args.oncreate).toHaveBeenCalledWith('test', '', 50);
		});
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 400px;">
			<NewRoleDialog open={args.open} oncreate={args.oncreate} />
		</div>
	{/snippet}
</Story>

<Story
	name="Reopen after a successful create shows an empty form"
	play={async () => {
		reopenCreate.mockClear();
		const body = within(document.body);
		await waitFor(() => expect(body.getByPlaceholderText('e.g. content_editor')).toBeVisible());

		await userEvent.type(body.getByPlaceholderText('e.g. content_editor'), 'clerk');
		await userEvent.type(body.getByLabelText('Level'), '50');
		await userEvent.type(body.getByLabelText(/Description/), 'Front desk clerk');
		await userEvent.click(body.getByRole('button', { name: 'Create role' }));

		// A successful create closes the dialog.
		await waitFor(() => expect(reopenOpen).toBe(false));

		// Reopen: the form must be empty again.
		reopenOpen = true;
		await waitFor(() => expect(body.getByPlaceholderText('e.g. content_editor')).toBeVisible());
		await expect(body.getByPlaceholderText('e.g. content_editor')).toHaveValue('');
		await expect(body.getByLabelText('Level')).toHaveValue('');
		await expect(body.getByLabelText(/Description/)).toHaveValue('');
	}}
>
	{#snippet template()}
		<div style="position: relative; width: 100%; min-height: 400px;">
			<NewRoleDialog bind:open={reopenOpen} oncreate={reopenCreate} />
		</div>
	{/snippet}
</Story>
