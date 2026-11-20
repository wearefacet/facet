<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { fn } from 'storybook/test';
	import PublishDialog from './PublishDialog.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Configure/PublishDialog',
		component: PublishDialog,
		tags: ['autodocs'],
		argTypes: {
			open: { control: false },
			draftDomain: { control: 'text' },
			initialName: { control: 'text' },
			check: { control: false }
		},
		args: {
			draftDomain: '_demo',
			initialName: '',
			onpublish: fn(async (): Promise<PublishOutcome> => ({ status: 'published', report: null }))
		},
		// A11y backlog (audit 22 — see .storybook/preview.ts): axe violations
		// on this surface (contrast / ARIA structure). Fix, then remove.
		parameters: { a11y: { test: 'todo' } }
	});
</script>

<script lang="ts">
	import { expect, within, userEvent, waitFor } from 'storybook/test';
	import type { DomainCheckResult } from '$lib/datasource/domainCheck.js';
	import type { PublishOutcome } from '$lib/builderDraft.svelte';
	import type { PublishReport } from './domainGrants.js';

	// Shared open state; each play closes any previous dialog before acting.
	let open = $state(false);

	// Mutable stand-ins for the draft-store snapshot pieces the root layout
	// passes down. The plays reassign them to reproduce a parent re-render
	// (each check refresh pushes a new snapshot object) while the dialog is
	// open — the condition under which a re-seed wipes the user's input.
	let liveInitialName = $state('');
	let liveCheck = $state<DomainCheckResult | undefined>(undefined);

	// The report `onpublish` resolves with when the backend filed or merged
	// grant tickets. The `Continue` target each play asserts on lives here.
	let continueTarget = $state<string | undefined>(undefined);

	// The 409-then-success mock for the overwrite-confirmation play: every
	// call without `overwrite` answers the conflict (as the backend does);
	// the confirmed overwrite publishes clean. The play resets and inspects
	// the call log directly (a plain function, not an instrumented mock —
	// the assertions are on this log, not the spy).
	let conflictPublishCalls: Array<[string, boolean]> = [];
	function conflictThenOk(targetName: string, overwrite: boolean): Promise<PublishOutcome> {
		conflictPublishCalls.push([targetName, overwrite]);
		if (!overwrite) {
			return Promise.resolve({
				status: 'conflict',
				message: "Target name 'orders' is already in use"
			});
		}
		return Promise.resolve({ status: 'published', report: null });
	}

	const warningCheck: DomainCheckResult = {
		domain: '_demo',
		issue_count: 2,
		domain_issues: [
			{
				severity: 'warning',
				category: 'reference',
				message: 'Target `acme.Customer` does not exist yet.'
			}
		],
		doctypes: [
			{
				doctype_id: '_demo.Order',
				issue_count: 1,
				issues: [
					{
						severity: 'warning',
						category: 'replication',
						message: 'Replication stays inert until publish.'
					}
				],
				notices: []
			}
		]
	};

	// One producer filed inactive (a non-admin publisher), one merged with
	// a re-acceptance drop, both pulling untagged fields via `default`.
	const ticketReport: PublishReport = {
		domain: 'orders',
		grant_tickets: [
			{
				producer: 'crm',
				filed: true,
				active: false,
				dropped: false,
				edges: [{ doctype: 'Company', tags: ['default'] }]
			},
			{
				producer: 'identity',
				filed: false,
				active: false,
				dropped: true,
				edges: [
					{ doctype: 'Person', tags: ['contact'] },
					{ doctype: 'Identifier', tags: ['default', 'pii'] }
				]
			}
		]
	};
</script>

<!--
	The dialog portals into `document.body`, so the play functions query
	`within(document.body)`. The plays toggle the shared `open` state
	directly (the `Toggle dialog` button exists for interactive preview
	only) — canvas clicks would fail here because an open dialog sets
	`pointer-events: none` on `<body>`.
-->

<Story
	name="StartsEmpty"
	play={async () => {
		const body = within(document.body);
		open = false;
		await waitFor(() => expect(body.queryByText('Publish draft domain')).toBeNull());

		open = true;
		await waitFor(() => expect(body.getByText('Publish draft domain')).toBeVisible());

		const input = body.getByLabelText('Target domain name');
		await expect(input).toHaveValue('');
		await expect(body.getByRole('button', { name: 'Publish' })).toBeDisabled();
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; min-height: 200px;">
			<button type="button" onclick={() => (open = !open)}>Toggle dialog</button>
			<PublishDialog bind:open draftDomain={args.draftDomain} onpublish={args.onpublish} />
		</div>
	{/snippet}
</Story>

<Story
	name="PrefillsInheritedName"
	args={{ initialName: 'orders' }}
	play={async ({ args }) => {
		const body = within(document.body);
		open = false;
		await waitFor(() => expect(body.queryByText('Publish draft domain')).toBeNull());

		open = true;
		await waitFor(() => expect(body.getByText('Publish draft domain')).toBeVisible());

		const input = body.getByLabelText('Target domain name');
		await expect(input).toHaveValue('orders');

		const publish = body.getByRole('button', { name: 'Publish' });
		await expect(publish).toBeEnabled();
		await userEvent.click(publish);
		await expect(args.onpublish).toHaveBeenCalledWith('orders', false, undefined);
		// Success closes the dialog.
		await waitFor(() => expect(body.queryByText('Publish draft domain')).toBeNull());
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; min-height: 200px;">
			<button type="button" onclick={() => (open = !open)}>Toggle dialog</button>
			<PublishDialog
				bind:open
				draftDomain={args.draftDomain}
				initialName={args.initialName}
				onpublish={args.onpublish}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ShowsWarnings"
	args={{ initialName: 'orders', check: warningCheck }}
	play={async ({ args }) => {
		const body = within(document.body);
		open = false;
		await waitFor(() => expect(body.queryByText('Publish draft domain')).toBeNull());

		open = true;
		await waitFor(() => expect(body.getByText('Publish draft domain')).toBeVisible());

		await expect(body.getByText('2 warnings detected')).toBeVisible();
		const publish = body.getByRole('button', { name: 'Publish with 2 warnings' });
		await expect(publish).toBeEnabled();
		await userEvent.click(publish);
		await expect(args.onpublish).toHaveBeenCalledWith('orders', false, undefined);
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; min-height: 200px;">
			<button type="button" onclick={() => (open = !open)}>Toggle dialog</button>
			<PublishDialog
				bind:open
				draftDomain={args.draftDomain}
				initialName={args.initialName}
				check={args.check}
				onpublish={args.onpublish}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ImportsSelectedDocuments"
	args={{
		initialName: 'orders',
		doctypes: [
			{ name: 'Status', count: 4, exists: false },
			{ name: 'Sample', count: 12, exists: false }
		]
	}}
	play={async ({ args }) => {
		const body = within(document.body);
		open = false;
		await waitFor(() => expect(body.queryByText('Publish draft domain')).toBeNull());

		open = true;
		await waitFor(() => expect(body.getByText('Publish draft domain')).toBeVisible());

		// Off by default: the doctype rows stay hidden until the toggle.
		await expect(body.queryByTestId('import-doctype-Status')).toBeNull();
		await userEvent.click(body.getByTestId('import-documents'));

		// Select all ticks every importable doctype, and the publish carries
		// them.
		await userEvent.click(body.getByTestId('import-documents-all'));
		await userEvent.click(body.getByRole('button', { name: 'Publish' }));
		await expect(args.onpublish).toHaveBeenCalledWith('orders', false, {
			import: true,
			doctypes: ['Status', 'Sample']
		});
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; min-height: 200px;">
			<button type="button" onclick={() => (open = !open)}>Toggle dialog</button>
			<PublishDialog
				bind:open
				draftDomain={args.draftDomain}
				initialName={args.initialName}
				doctypes={args.doctypes}
				onpublish={args.onpublish}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="DisablesExistingDoctype"
	args={{
		initialName: 'orders',
		doctypes: [
			{ name: 'Status', count: 4, exists: false },
			{ name: 'Order', count: 30, exists: true }
		]
	}}
	play={async () => {
		const body = within(document.body);
		open = false;
		await waitFor(() => expect(body.queryByText('Publish draft domain')).toBeNull());

		open = true;
		await waitFor(() => expect(body.getByText('Publish draft domain')).toBeVisible());
		await userEvent.click(body.getByTestId('import-documents'));

		// A doctype the live target already defines is disabled, so draft rows
		// never mix with production rows.
		await expect(body.getByTestId('import-doctype-Order')).toBeDisabled();
		await expect(body.getByTestId('import-doctype-Status')).toBeEnabled();
		await expect(body.getByText('Already exists on the target — not imported')).toBeVisible();

		// Select all skips the disabled row.
		await userEvent.click(body.getByTestId('import-documents-all'));
		await expect(body.getByTestId('import-doctype-Status')).toBeChecked();
		await expect(body.getByTestId('import-doctype-Order')).not.toBeChecked();
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; min-height: 200px;">
			<button type="button" onclick={() => (open = !open)}>Toggle dialog</button>
			<PublishDialog
				bind:open
				draftDomain={args.draftDomain}
				initialName={args.initialName}
				doctypes={args.doctypes}
				onpublish={args.onpublish}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ShowsTicketReport"
	args={{ initialName: 'orders' }}
	play={async () => {
		const body = within(document.body);
		open = false;
		continueTarget = undefined;
		await waitFor(() => expect(body.queryByText('Publish draft domain')).toBeNull());

		open = true;
		await waitFor(() => expect(body.getByText('Publish draft domain')).toBeVisible());

		const publish = body.getByRole('button', { name: 'Publish' });
		await userEvent.click(publish);

		// The report replaces the form: one section per producer with the
		// resulting acceptance state, and the re-acceptance warning on the
		// dropped grant. Both fixtures pull `default`, so both carry the
		// untagged-fields warning.
		await waitFor(() => expect(body.getByText('Domain published')).toBeVisible());
		await expect(body.getByText('from crm')).toBeVisible();
		await expect(body.getByText('from identity')).toBeVisible();
		await expect(body.getAllByText('Awaiting acceptance')).toHaveLength(2);
		await expect(body.getByText(/re-acceptance/)).toBeVisible();
		await expect(body.getAllByText(/untagged fields/)).toHaveLength(2);

		// The only exit is the continue button — the draft is gone.
		await userEvent.click(body.getByRole('button', { name: 'Go to orders' }));
		await waitFor(() => expect(body.queryByText('Domain published')).toBeNull());
		await expect(continueTarget).toBe('orders');
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; min-height: 200px;">
			<button type="button" onclick={() => (open = !open)}>Toggle dialog</button>
			<PublishDialog
				bind:open
				draftDomain={args.draftDomain}
				initialName={args.initialName}
				onpublish={async () => ({ status: 'published', report: ticketReport })}
				oncontinue={(domain) => (continueTarget = domain)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ReportBlocksBareClose"
	args={{ initialName: 'orders' }}
	play={async () => {
		const body = within(document.body);
		open = false;
		continueTarget = undefined;
		await waitFor(() => expect(body.queryByText('Publish draft domain')).toBeNull());

		open = true;
		await waitFor(() => expect(body.getByText('Publish draft domain')).toBeVisible());

		await userEvent.click(body.getByRole('button', { name: 'Publish' }));
		await waitFor(() => expect(body.getByText('Domain published')).toBeVisible());

		// Esc and an outside click must not close the report: its only exit
		// is the continue button, which navigates (a bare close would strand
		// the user on the dead draft URL).
		await userEvent.keyboard('{Escape}');
		await expect(body.getByText('Domain published')).toBeVisible();

		const overlay = document.querySelector('.publish-overlay');
		await userEvent.click(overlay as HTMLElement);
		await expect(body.getByText('Domain published')).toBeVisible();

		await userEvent.click(body.getByRole('button', { name: 'Go to orders' }));
		await waitFor(() => expect(body.queryByText('Domain published')).toBeNull());
		await expect(continueTarget).toBe('orders');
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; min-height: 200px;">
			<button type="button" onclick={() => (open = !open)}>Toggle dialog</button>
			<PublishDialog
				bind:open
				draftDomain={args.draftDomain}
				initialName={args.initialName}
				onpublish={async () => ({ status: 'published', report: ticketReport })}
				oncontinue={(domain) => (continueTarget = domain)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ReportWithActiveTicket"
	args={{ initialName: 'orders' }}
	play={async () => {
		const body = within(document.body);
		open = false;
		continueTarget = undefined;
		await waitFor(() => expect(body.queryByText('Publish draft domain')).toBeNull());

		open = true;
		await waitFor(() => expect(body.getByText('Publish draft domain')).toBeVisible());

		await userEvent.click(body.getByRole('button', { name: 'Publish' }));

		// A publisher holding the acceptance right (D11) files active — the
		// ticket renders Active with no re-acceptance warning.
		await waitFor(() => expect(body.getByText('Domain published')).toBeVisible());
		await expect(body.getByText('Active')).toBeVisible();
		await expect(body.queryByText(/re-acceptance/)).toBeNull();
		await userEvent.click(body.getByRole('button', { name: 'Go to orders' }));
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; min-height: 200px;">
			<button type="button" onclick={() => (open = !open)}>Toggle dialog</button>
			<PublishDialog
				bind:open
				draftDomain={args.draftDomain}
				initialName={args.initialName}
				onpublish={async () => ({
					status: 'published',
					report: {
						domain: 'orders',
						grant_tickets: [
							{
								producer: 'hr',
								filed: true,
								active: true,
								dropped: false,
								edges: [{ doctype: 'Candidate', tags: ['default'] }]
							}
						]
					}
				})}
				oncontinue={(domain) => (continueTarget = domain)}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="KeepsEditWhileParentRerenders"
	play={async () => {
		const body = within(document.body);
		open = false;
		liveInitialName = 'crm';
		liveCheck = undefined;
		await waitFor(() => expect(body.queryByText('Publish draft domain')).toBeNull());

		open = true;
		await waitFor(() => expect(body.getByText('Publish draft domain')).toBeVisible());

		const input = body.getByLabelText('Target domain name');
		await expect(input).toHaveValue('crm');

		await userEvent.clear(input);
		await userEvent.type(input, 'crmdraft');
		await expect(input).toHaveValue('crmdraft');

		// A check fetch lands while the dialog is open: the parent pushes a new
		// snapshot (new `check` object, same `initialName` string). The dialog
		// must keep the typed name — a re-seed here once made the submit fire
		// under the prefill (the e2e overwrite phase published over the live
		// source domain that way).
		liveCheck = {
			...warningCheck,
			issue_count: warningCheck.issue_count + 1
		};
		await waitFor(() => expect(body.getByText('3 warnings detected')).toBeVisible());
		await expect(input).toHaveValue('crmdraft');

		const publish = body.getByRole('button', { name: 'Publish with 3 warnings' });
		await userEvent.click(publish);
		await expect(body.getByRole('alert')).toHaveTextContent('Publish failed: HTTP 409');
		// The failed submit must not re-seed either.
		await expect(input).toHaveValue('crmdraft');
	}}
>
	{#snippet template()}
		<div style="padding: 24px; min-height: 200px;">
			<button type="button" onclick={() => (open = !open)}>Toggle dialog</button>
			<PublishDialog
				bind:open
				draftDomain="_demo"
				initialName={liveInitialName}
				check={liveCheck}
				onpublish={async () => ({ status: 'error', message: 'Publish failed: HTTP 409' })}
			/>
		</div>
	{/snippet}
</Story>

<Story
	name="ConflictsThenConfirmsOverwrite"
	args={{ initialName: 'orders' }}
	play={async () => {
		const body = within(document.body);
		open = false;
		conflictPublishCalls = [];
		await waitFor(() => expect(body.queryByText('Publish draft domain')).toBeNull());

		open = true;
		await waitFor(() => expect(body.getByText('Publish draft domain')).toBeVisible());

		// First attempt: the backend answers 409 — the form gives way to the
		// explicit overwrite confirmation (B-353; the silent auto-retry is gone).
		await userEvent.click(body.getByRole('button', { name: 'Publish' }));
		await waitFor(() =>
			expect(body.getByText(/A live domain named `orders` already exists/)).toBeVisible()
		);
		await expect(conflictPublishCalls).toEqual([['orders', false]]);

		// Going back keeps the typed name in the form.
		await userEvent.click(body.getByRole('button', { name: 'Choose another name' }));
		await expect(body.getByLabelText('Target domain name')).toHaveValue('orders');

		// The confirmed retry carries `overwrite: true` and closes on success.
		await userEvent.click(body.getByRole('button', { name: 'Publish' }));
		await waitFor(() =>
			expect(body.getByText(/A live domain named `orders` already exists/)).toBeVisible()
		);
		await userEvent.click(body.getByRole('button', { name: 'Publish over orders' }));
		await expect(conflictPublishCalls).toEqual([
			['orders', false],
			['orders', false],
			['orders', true]
		]);
		await waitFor(() => expect(body.queryByText('Publish draft domain')).toBeNull());
	}}
>
	{#snippet template(args)}
		<div style="padding: 24px; min-height: 200px;">
			<button type="button" onclick={() => (open = !open)}>Toggle dialog</button>
			<PublishDialog
				bind:open
				draftDomain={args.draftDomain}
				initialName={args.initialName}
				onpublish={conflictThenOk}
			/>
		</div>
	{/snippet}
</Story>
