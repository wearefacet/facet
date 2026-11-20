<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, userEvent, waitFor, within, fn } from 'storybook/test';
	import { tick } from 'svelte';
	import ActionArgsDialog from './ActionArgsDialog.svelte';
	import { createMockDriver } from '$lib/datasource/mock-seed.js';
	import type { ActionDef } from '$lib/doctype/types.js';
	import type { BannerError } from '$lib/datasource/bannerError.js';

	const driver = createMockDriver();

	/** One required text arg plus one bounded optional integer — the play surface. */
	const closeAction: ActionDef = {
		key: 'close',
		label: 'Close',
		description: 'Close the case with a reason.',
		args: [
			{ key: 'reason', type: 'string', required: true },
			{ key: 'level', type: 'integer', min: 1, max: 10 }
		]
	};

	/** Every mapped arg type renders its control (visual coverage, no play).
	 *  The reference picker carries known axe violations (audit 22) — the
	 *  story inherits the `a11y: todo` override below. */
	const allControlsAction: ActionDef = {
		key: 'relocate',
		args: [
			{ key: 'note', type: 'string' },
			{ key: 'count', type: 'integer' },
			{ key: 'budget', type: 'money' },
			{ key: 'active', type: 'boolean' },
			{ key: 'stage', type: 'enum', values: [{ key: 'draft' }, { key: 'final' }] },
			{ key: 'target', type: 'reference', doctype: 'crm.Company' },
			{ key: 'day', type: 'date' },
			{ key: 'at', type: 'datetime' }
		]
	};

	// The dialog is controlled, so the stories drive one shared open flag.
	// Each play resets it first — stories share one iframe (isolate: false),
	// and residue from a previous story must never leak into the next one.
	let open = $state(false);
	// The host's action failure, rendered by the prompt while it stays open.
	let failureError = $state<BannerError | null>(null);

	async function resetPrompt(): Promise<void> {
		open = false;
		failureError = null;
		await tick();
	}

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/ActionArgsDialog',
		component: ActionArgsDialog,
		tags: ['autodocs'],
		argTypes: {
			open: { control: 'boolean' }
		},
		args: {
			onsubmit: fn()
		}
	});
</script>

<!-- The menu item's contract: clicking it opens the prompt with one
	control per argument, and Cancel closes it without submitting. -->
<Story
	name="PromptOpens"
	play={async ({ canvasElement }) => {
		await resetPrompt();
		const canvas = within(canvasElement);
		const body = within(document.body);

		await userEvent.click(canvas.getByRole('button', { name: 'Open args prompt' }));
		await waitFor(() => expect(body.getByText('Close')).toBeVisible());
		// The required marker rides inside the label text — match with a regex.
		await expect(body.getByText(/Reason/)).toBeVisible();
		await expect(body.getByLabelText(/Level/)).toBeVisible();

		await userEvent.click(body.getByRole('button', { name: 'Cancel' }));
		await waitFor(() => expect(body.queryByText('Close')).toBeNull());
	}}
>
	{#snippet template()}
		<div style="min-height: 400px; padding: 24px;">
			<button type="button" onclick={() => (open = true)}>Open args prompt</button>
			<ActionArgsDialog
				bind:open
				action={closeAction}
				{driver}
				domain="crm"
				onsubmit={() => {
					/* noop in story */
				}}
			/>
		</div>
	{/snippet}
</Story>

<!-- Required blocks the submit: an empty prompt shows the required error on
	the unfilled arg, and an out-of-range integer shows the range error —
	neither submit reaches the host. -->
<Story
	name="ValidationBlocksSubmit"
	play={async ({ canvasElement, args }) => {
		await resetPrompt();
		const canvas = within(canvasElement);
		const body = within(document.body);

		await userEvent.click(canvas.getByRole('button', { name: 'Open args prompt' }));
		await waitFor(() => expect(body.getByText('Close')).toBeVisible());

		// Out of range: the optional integer accepts 99 but the bound is 10.
		await userEvent.type(body.getByLabelText(/Level/), '99');
		await userEvent.click(body.getByRole('button', { name: 'Confirm' }));
		await waitFor(() => expect(body.getAllByText('This field is required.')).toHaveLength(1));
		await expect(body.getByText(/out of range/)).toBeVisible();
		expect(args.onsubmit).not.toHaveBeenCalled();

		// The prompt stays open until a valid submit or a cancel.
		await userEvent.click(body.getByRole('button', { name: 'Cancel' }));
		await waitFor(() => expect(body.queryByText('Close')).toBeNull());
	}}
>
	{#snippet template(args)}
		<div style="min-height: 400px; padding: 24px;">
			<button type="button" onclick={() => (open = true)}>Open args prompt</button>
			<ActionArgsDialog
				bind:open
				action={closeAction}
				{driver}
				domain="crm"
				onsubmit={args.onsubmit}
			/>
		</div>
	{/snippet}
</Story>

<!-- A valid submit hands the collected args to the host (empty optional
	values stay absent keys) and closes the prompt. -->
<Story
	name="SubmitCallsWithArgs"
	play={async ({ canvasElement, args }) => {
		await resetPrompt();
		const canvas = within(canvasElement);
		const body = within(document.body);

		await userEvent.click(canvas.getByRole('button', { name: 'Open args prompt' }));
		await waitFor(() => expect(body.getByText('Close')).toBeVisible());

		await userEvent.type(body.getByLabelText(/Reason/), 'Sorted.');
		await userEvent.type(body.getByLabelText(/Level/), '3');
		await userEvent.click(body.getByRole('button', { name: 'Confirm' }));

		await waitFor(() =>
			expect(args.onsubmit).toHaveBeenCalledWith({ reason: 'Sorted.', level: 3 })
		);
		await waitFor(() => expect(body.queryByText('Close')).toBeNull());
	}}
>
	{#snippet template(args)}
		<div style="min-height: 400px; padding: 24px;">
			<button type="button" onclick={() => (open = true)}>Open args prompt</button>
			<ActionArgsDialog
				bind:open
				action={closeAction}
				{driver}
				domain="crm"
				onsubmit={args.onsubmit}
			/>
		</div>
	{/snippet}
</Story>

<!-- A failed action keeps the prompt open and renders the backend detail so
	the user can correct the arguments and retry. -->
<Story
	name="FailureKeepsPromptOpen"
	play={async ({ canvasElement }) => {
		await resetPrompt();
		const canvas = within(canvasElement);
		const body = within(document.body);

		await userEvent.click(canvas.getByRole('button', { name: 'Open args prompt' }));
		await waitFor(() => expect(body.getByText('Close')).toBeVisible());

		await userEvent.type(body.getByLabelText(/Reason/), 'Sorted.');
		await userEvent.click(body.getByRole('button', { name: 'Confirm' }));

		// The host rejects: the prompt stays open and shows the detail line.
		await waitFor(() => expect(body.getByText('deliberate boom')).toBeVisible());
		await expect(body.getByText('Close')).toBeVisible();
	}}
>
	{#snippet template()}
		<div style="min-height: 400px; padding: 24px;">
			<button type="button" onclick={() => (open = true)}>Open args prompt</button>
			<ActionArgsDialog
				bind:open
				action={closeAction}
				{driver}
				domain="crm"
				error={failureError}
				onsubmit={async () => {
					failureError = { message: 'Action failed', details: ['deliberate boom'] };
					return false;
				}}
			/>
		</div>
	{/snippet}
</Story>

<!-- Visual catalogue: every mapped arg type renders its control (no play). -->
<Story
	name="AllArgControls"
	parameters={{
		// The ReferencePicker surface carries known axe violations (audit 22,
		// see its own stories) — inherited by this story that embeds it.
		a11y: { test: 'todo' }
	}}
>
	{#snippet template()}
		<div style="min-height: 400px; padding: 24px;">
			<ActionArgsDialog
				open
				action={allControlsAction}
				{driver}
				domain="crm"
				onsubmit={() => {
					/* noop in story */
				}}
			/>
		</div>
	{/snippet}
</Story>
