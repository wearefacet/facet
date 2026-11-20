<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import Button from '../actions/Button.svelte';
	import PageHeader from './PageHeader.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Surfaces/PageHeader',
		component: PageHeader,
		tags: ['autodocs']
	});
</script>

{#snippet newButton()}
	<Button variant="primary">New empty domain</Button>
{/snippet}

<Story
	name="Default"
	args={{ title: 'Domains' }}
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Domains')).toBeVisible();
	}}
/>

<Story
	name="WithSubtitle"
	args={{
		title: 'Roles',
		subtitle: 'Application-global roles. Each role has members and grants per domain.'
	}}
/>

<Story name="WithActions" args={{ title: 'Domains' }}>
	{#snippet template(args)}
		<PageHeader title={args.title}>
			{#snippet actions()}
				{@render newButton()}
			{/snippet}
		</PageHeader>
	{/snippet}
</Story>
