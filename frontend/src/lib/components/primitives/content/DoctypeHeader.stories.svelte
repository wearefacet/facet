<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import Button from '../actions/Button.svelte';
	import DoctypeHeader from './DoctypeHeader.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Content/DoctypeHeader',
		component: DoctypeHeader,
		tags: ['autodocs']
	});
</script>

{#snippet editAction()}
	<Button variant="secondary" size="sm">Edit</Button>
{/snippet}

<Story
	name="Show"
	args={{
		title: 'Acme Corp',
		color: '#3b82f6',
		backHref: '/crm/Company',
		backLabel: 'Company',
		version: 3,
		qualifiedName: 'crm.Company'
	}}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Acme Corp')).toBeVisible();
		await expect(canvas.getByText('crm.Company')).toBeVisible();
		await expect(canvas.getByText('v3')).toBeVisible();
	}}
/>

<Story name="WithActions" args={{ title: 'Edit Acme Corp', color: '#3b82f6', version: 3 }}>
	{#snippet template(args)}
		<DoctypeHeader title={args.title} color={args.color} version={args.version}>
			{#snippet actions()}
				{@render editAction()}
			{/snippet}
		</DoctypeHeader>
	{/snippet}
</Story>

<Story
	name="NoBackLink"
	args={{ title: 'New Company', color: '#3b82f6', qualifiedName: 'crm.Company' }}
/>
