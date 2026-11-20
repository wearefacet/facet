<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { MockDataDriver } from '$lib/datasource/MockDriver.js';
	import type { DataDriver } from '$lib/datasource/driver.js';
	import WebhookDialog from './WebhookDialog.svelte';

	const { Story } = defineMeta({
		component: WebhookDialog,
		title: 'Components/Features/Settings/WebhookDialog',
		tags: ['autodocs']
	});

	// Component tests for the create / edit dialog. `onsave` is synthetic —
	// the stories assert the observable form behaviour: the events tri-state
	// (absent = all events), the header editor, and inline save errors.
	// Create-mode stories hardcode `webhook={null}` in the template — a null
	// args value crashes the story-source emitter (see workflow.md).
	// Bits UI portals the dialog into `document.body`, so the plays query
	// `within(document.body)` and close the dialog at the end so later
	// stories see a clean portal.

	const DOCTYPE_SEED = [
		{ id: 'crm.Invoice', domain: 'crm', doctype: 'Invoice', color: '#566688' },
		{ id: 'hr.Employee', domain: 'hr', doctype: 'Employee', color: '#566688' }
	];

	function driver(): DataDriver {
		const d = new MockDataDriver();
		d.domain('core').doctype(
			'DocType',
			DOCTYPE_SEED.map((s) => ({ ...s }))
		);
		return d;
	}

	async function closeDialog() {
		const body = within(document.body);
		// A prior story's modal cleanup can leave `pointer-events: none` on
		// `<body>` for a tick — retry the Escape keypress until it lands
		// (see workflow.md → Storybook play conventions).
		await waitFor(async () => {
			await userEvent.keyboard('{Escape}');
			expect(body.queryByText('Save')).toBeNull();
		});
	}
</script>

<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts">
	// The play functions run in the instance script — `within` must be
	// imported there (the ApiKeyRevealDialog stories set the pattern).
	import { expect, userEvent, waitFor, within } from 'storybook/test';

	// Shared open state for the reopen story: the dialog is controlled through a
	// real binding so the play can close it (Cancel) and open it again — the
	// path that used to leak the previous entry into the fresh form.
	let reopenOpen = $state(true);
</script>

<Story
	name="CreateBlocksEmptySubmit"
	args={{ open: true }}
	play={async ({ canvasElement, args }) => {
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('New webhook')).toBeVisible());
		expect(body.getByLabelText('Name')).toBeInTheDocument();
		expect(body.getByLabelText('Target URL')).toBeInTheDocument();
		expect(body.getByText('Fire on all events')).toBeInTheDocument();
		// Submit stays disabled until the required fields are filled.
		expect(body.getByRole('button', { name: 'Save' })).toBeDisabled();
		void canvasElement;
		void args;
		await closeDialog();
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 400px;">
			<WebhookDialog open={args.open} webhook={null} driver={driver()} />
		</div>
	{/snippet}
</Story>

<Story
	name="AllEventsToggleShowsList"
	args={{ open: true }}
	play={async ({ canvasElement, args }) => {
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('New webhook')).toBeVisible());
		// Default: fire on all events — the subset list is hidden.
		const toggle = body.getByRole('switch');
		expect(toggle).toHaveAttribute('aria-checked', 'true');
		expect(body.queryByText('Events')).not.toBeInTheDocument();
		await userEvent.click(toggle);
		await waitFor(() => expect(body.getByText('Events')).toBeInTheDocument());
		void canvasElement;
		void args;
		await closeDialog();
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 400px;">
			<WebhookDialog open={args.open} webhook={null} driver={driver()} />
		</div>
	{/snippet}
</Story>

<Story
	name="EditSeedsStoredValues"
	args={{ open: true }}
	play={async ({ canvasElement, args }) => {
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('Edit webhook')).toBeVisible());
		expect(body.getByLabelText('Name')).toHaveValue('Billing sync');
		expect(body.getByLabelText('Target URL')).toHaveValue('https://billing.example.test/hooks');
		// A stored events array switches the toggle off and lists the subset.
		const toggle = body.getByRole('switch');
		expect(toggle).toHaveAttribute('aria-checked', 'false');
		expect(body.getByText('Events')).toBeInTheDocument();
		void canvasElement;
		void args;
		await closeDialog();
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 400px;">
			<WebhookDialog
				open={args.open}
				webhook={{
					label: 'Billing sync',
					url: 'https://billing.example.test/hooks',
					source_doctype: 'core.DocType.crm.Invoice',
					events: ['created']
				}}
				driver={driver()}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="HeaderKeyValidation"
	args={{ open: true }}
	play={async ({ canvasElement, args }) => {
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('New webhook')).toBeVisible());
		await userEvent.click(body.getByRole('button', { name: '+ Add header' }));
		const keyInput = body.getByLabelText('Header 1 name');
		await userEvent.type(keyInput, 'X-Facet-Event');
		await waitFor(() =>
			expect(body.getByText('Headers starting with X-Facet- are reserved')).toBeInTheDocument()
		);
		void canvasElement;
		void args;
		await closeDialog();
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 400px;">
			<WebhookDialog open={args.open} webhook={null} driver={driver()} />
		</div>
	{/snippet}
</Story>

<Story
	name="SaveErrorShowsInline"
	args={{ open: true }}
	play={async ({ canvasElement, args }) => {
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('Edit webhook')).toBeVisible());
		// A save rejection renders verbatim; the dialog stays open.
		await userEvent.click(body.getByRole('button', { name: 'Save' }));
		await waitFor(() => expect(body.getByText('URL is not reachable (422)')).toBeInTheDocument());
		expect(body.getByText('Edit webhook')).toBeInTheDocument();
		void canvasElement;
		void args;
		await closeDialog();
	}}
>
	{#snippet template(args)}
		<div style="position: relative; width: 100%; min-height: 400px;">
			<WebhookDialog
				open={args.open}
				webhook={{
					label: 'Existing',
					url: 'https://rcvr.example.test/hook',
					source_doctype: 'core.DocType.crm.Invoice'
				}}
				driver={driver()}
				onsave={async () => 'URL is not reachable (422)'}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ReopenAfterCancelShowsAnEmptyForm"
	play={async () => {
		const body = within(document.body);
		await waitFor(() => expect(body.getByText('New webhook')).toBeVisible());

		await userEvent.type(body.getByLabelText('Name'), 'Draft hook');
		await expect(body.getByLabelText('Name')).toHaveValue('Draft hook');

		// Cancel closes the dialog programmatically — no `onOpenChange` fires.
		await userEvent.click(body.getByRole('button', { name: 'Cancel' }));
		await waitFor(() => expect(reopenOpen).toBe(false));

		// Reopen: the form must be empty again.
		reopenOpen = true;
		await waitFor(() => expect(body.getByText('New webhook')).toBeVisible());
		await expect(body.getByLabelText('Name')).toHaveValue('');

		// Close so the a11y scan does not see the (pre-existing) nested-interactive
		// violation in the portalled ReferencePicker.
		await closeDialog();
	}}
>
	{#snippet template()}
		<div style="position: relative; width: 100%; min-height: 400px;">
			<WebhookDialog bind:open={reopenOpen} webhook={null} driver={driver()} />
		</div>
	{/snippet}
</Story>
