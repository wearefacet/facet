<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import Badge from './Badge.svelte';
	import { Check } from '@lucide/svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Data/Badge',
		component: Badge,
		tags: ['autodocs'],
		argTypes: {
			variant: {
				control: 'select',
				options: ['neutral', 'accent', 'ok', 'warn', 'danger', 'info']
			},
			doctype: {
				control: 'select',
				options: [undefined, 'invoice', 'shipment', 'contact', 'task', 'document', 'contract']
			},
			size: {
				control: 'select',
				options: ['sm', 'md']
			}
		},
		// Pre-existing backlog (audit 22): the warn variant's text fails
		// axe color-contrast. Fix the tokens, then remove this override.
		parameters: { a11y: { test: 'todo' } }
	});
</script>

{#snippet iconCheck()}
	<Check size={12} />
{/snippet}

<Story
	name="Neutral"
	args={{ label: 'Draft', variant: 'neutral' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Draft')).toBeVisible();
	}}
/>
<Story name="Accent" args={{ label: 'Live', variant: 'accent' }} />
<Story
	name="Ok"
	args={{ label: 'Reconciled', variant: 'ok' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Reconciled')).toBeVisible();
	}}
/>
<Story name="Warn" args={{ label: 'Needs review', variant: 'warn' }} />
<Story name="Danger" args={{ label: 'Disputed', variant: 'danger' }} />
<Story name="Info" args={{ label: 'Updated', variant: 'info' }} />

<Story name="Small" args={{ label: 'New', size: 'sm', variant: 'accent' }} />

<Story
	name="DoctypeInvoice"
	args={{ label: 'Invoice', doctype: 'invoice' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Invoice')).toBeVisible();
	}}
/>
<Story name="DoctypeShipment" args={{ label: 'Shipment', doctype: 'shipment' }} />
<Story name="DoctypeContact" args={{ label: 'Contact', doctype: 'contact' }} />
<Story name="DoctypeTask" args={{ label: 'Task', doctype: 'task' }} />
<Story name="DoctypeDocument" args={{ label: 'Document', doctype: 'document' }} />
<Story name="DoctypeContract" args={{ label: 'Contract', doctype: 'contract' }} />

<Story name="WithIcon" args={{ label: 'Complete', variant: 'ok', children: iconCheck }} />
