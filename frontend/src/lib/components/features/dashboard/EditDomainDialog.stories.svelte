<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within, waitFor } from 'storybook/test';
	import EditDomainDialog from './EditDomainDialog.svelte';
	import type { NavDomain } from '$lib/navTypes';
	import { setPermissions } from '$lib/permissions.svelte';
	import * as m from '$lib/paraglide/messages';

	const sampleLiveDomains: NavDomain[] = [
		{
			id: 'crm',
			label: 'CRM',
			color: '#3F51B5',
			doctypes: [
				{ qualified: 'crm.Company', label: 'Company', color: '#3F51B5', count: 248 },
				{ qualified: 'crm.Contact', label: 'Contact', color: '#1B5E20', count: 1200 }
			]
		},
		{
			id: 'hr',
			label: 'Human Resources',
			color: '#E91E63',
			doctypes: [{ qualified: 'hr.Employee', label: 'Employee', color: '#E91E63', count: 47 }]
		},
		{
			id: 'orders',
			label: 'Orders',
			color: '#FF9800',
			doctypes: [
				{ qualified: 'orders.Invoice', label: 'Invoice', color: '#FF9800', count: 512 },
				{ qualified: 'orders.Shipment', label: 'Shipment', color: '#4CAF50', count: 71 }
			]
		}
	];

	const { Story } = defineMeta({
		title: 'Components/Features/Dashboard/EditDomainDialog',
		component: EditDomainDialog,
		tags: ['autodocs'],
		argTypes: {
			open: { control: 'boolean' },
			error: { control: 'text' }
		},
		args: {
			open: true,
			error: undefined
		}
	});
</script>

<script lang="ts">
	const emptyDomains: NavDomain[] = [];

	// The dialog gates the Edit buttons on the global permission store
	// (`can('core.Domain', 'create')`). Grant the admin wildcard at mount so
	// the default stories show enabled buttons; the permission story swaps
	// the manifest inside its play and restores it.
	setPermissions({ '*.*': ['*'] });
</script>

{#snippet chrome(
	args: Record<string, unknown>,
	liveDomains: NavDomain[],
	error: string | undefined
)}
	<div style="position: relative; width: 100%; min-height: 400px;">
		<EditDomainDialog
			open={args.open as boolean}
			{liveDomains}
			{error}
			onselect={() => {
				/* noop in story */
			}}
		/>
	</div>
{/snippet}

<Story name="Three Live Domains" args={{ open: true }}>
	{#snippet template(args)}
		{@render chrome(args, sampleLiveDomains, undefined)}
	{/snippet}
</Story>

<Story name="Empty — No Live Domains" args={{ open: true }}>
	{#snippet template(args)}
		{@render chrome(args, emptyDomains, undefined)}
	{/snippet}
</Story>

<Story name="Draft Already Exists (409)" args={{ open: true }}>
	{#snippet template(args)}
		{@render chrome(args, sampleLiveDomains, 'A draft already exists for domain "hr"')}
	{/snippet}
</Story>

<Story
	name="Draft Forbidden (403) Shows Friendly Error"
	args={{ open: true, error: m.builder_edit_domain_forbidden() }}
	play={async ({ canvasElement: _canvasElement }) => {
		// Bits UI Dialog.Portal mounts into document.body, so query there.
		const body = within(document.body);
		await expect(body.getByRole('alert')).toHaveTextContent(m.builder_edit_domain_forbidden());
	}}
>
	{#snippet template(args)}
		{@render chrome(args, sampleLiveDomains, args.error as string)}
	{/snippet}
</Story>

<Story
	name="No Create Permission Disables Edit"
	args={{ open: true }}
	play={async ({ canvasElement: _canvasElement }) => {
		// Bits UI Dialog.Portal mounts into document.body, so query there.
		const body = within(document.body);
		// Swap in a read-only manifest — the dialog must disable every Edit
		// button with a reason. Restore the admin wildcard afterwards.
		setPermissions({ '*.*': ['read'] });
		await waitFor(() =>
			expect(body.getAllByRole('button', { name: m.common_edit() })).toHaveLength(3)
		);
		const buttons = body.getAllByRole('button', { name: m.common_edit() });
		for (const btn of buttons) {
			await expect(btn).toBeDisabled();
			await expect(btn).toHaveAttribute('title', m.builder_edit_domain_forbidden());
		}
		setPermissions({ '*.*': ['*'] });
	}}
>
	{#snippet template(args)}
		{@render chrome(args, sampleLiveDomains, undefined)}
	{/snippet}
</Story>

<Story
	name="Create Permission Keeps Edit Enabled"
	args={{ open: true }}
	play={async ({ canvasElement: _canvasElement }) => {
		// Bits UI Dialog.Portal mounts into document.body, so query there.
		const body = within(document.body);
		// Grant the admin wildcard explicitly — the mount-time hydration is
		// not part of the assertion.
		setPermissions({ '*.*': ['*'] });
		const buttons = body.getAllByRole('button', { name: m.common_edit() });
		expect(buttons).toHaveLength(3);
		for (const btn of buttons) {
			await expect(btn).toBeEnabled();
			await expect(btn).not.toHaveAttribute('title');
		}
	}}
>
	{#snippet template(args)}
		{@render chrome(args, sampleLiveDomains, undefined)}
	{/snippet}
</Story>
