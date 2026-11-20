<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import EmptyDomainsCard from './EmptyDomainsCard.svelte';

	const { Story } = defineMeta({
		title: 'Components/Features/Dashboard/EmptyDomainsCard',
		component: EmptyDomainsCard,
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
</script>

<!--
	The NewDomainDialog portals into `document.body`, so the play functions
	query `within(document.body)`. `oncreate` is injected — no network call
	runs in stories.
-->

<Story
	name="RendersTheCreateHint"
	play={async ({ canvasElement }) => {
		resetSpy();
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Create or import your first domain')).toBeVisible();
		await expect(
			canvas.getByText(
				'A domain holds one business area of your organization. Create your first domain, or import a bundle from another Facet instance.'
			)
		).toBeVisible();
		await expect(canvas.getByRole('button', { name: 'New domain' })).toBeVisible();

		// The secondary affordance deep-links the domains page's import dialog.
		// `Button` renders its `href` variant as an `<a role="button">`.
		const importBtn = canvas.getByRole('button', { name: 'Import a bundle' });
		await expect(importBtn).toHaveAttribute('href', '/Configure/domains?import=1');
	}}
>
	{#snippet template()}
		<div style="width: 480px; padding: 24px; background: var(--ground);">
			<EmptyDomainsCard oncreate={createSpy} />
		</div>
	{/snippet}
</Story>

<Story
	name="NewDomainOpensTheDialogAndCallsOncreate"
	play={async ({ canvasElement }) => {
		resetSpy();
		const canvas = within(canvasElement);
		const body = within(document.body);

		await userEvent.click(canvas.getByRole('button', { name: 'New domain' }));
		// The dialog's label input is unique to the portal — the card's own
		// "New domain" button shares the dialog title's text.
		const labelInput = body.getByLabelText('Label');
		await waitFor(() => expect(labelInput).toBeVisible());

		await userEvent.type(labelInput, 'CRM');
		// The id infers from the label per the domain-name contract.
		await expect(body.getByLabelText('Domain id')).toHaveValue('crm');
		await userEvent.click(body.getByRole('button', { name: 'Create draft' }));

		await waitFor(() => expect(createCalls).toEqual([{ name: 'crm', label: 'CRM' }]));
		// Success closes the dialog.
		await waitFor(() => expect(body.queryByLabelText('Label')).toBeNull());

		// Reopen: the form must be empty again. A programmatic close (the
		// successful create above) does not fire Bits UI's `onOpenChange`, so the
		// reset keys off the open edge. The modal cleanup can leave
		// `pointer-events: none` on `<body>` for a tick — retry the click.
		await waitFor(async () => {
			await userEvent.click(canvas.getByRole('button', { name: 'New domain' }));
			expect(body.getByLabelText('Label')).toBeVisible();
		});
		await expect(body.getByLabelText('Label')).toHaveValue('');
	}}
>
	{#snippet template()}
		<div style="width: 480px; padding: 24px; background: var(--ground);">
			<EmptyDomainsCard oncreate={createSpy} />
		</div>
	{/snippet}
</Story>
