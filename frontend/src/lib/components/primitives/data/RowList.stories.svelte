<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import RowList from './RowList.svelte';
	import RowItem from './RowItem.svelte';

	const { Story } = defineMeta({
		title: 'Components/Primitives/Data/RowList',
		component: RowList,
		tags: ['autodocs']
	});
</script>

<Story
	name="WithRows"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Alpha')).toBeVisible();
		await expect(canvas.getByText('Beta')).toBeVisible();
	}}
>
	{#snippet template()}
		<RowList>
			<RowItem>
				<span>Alpha</span>
			</RowItem>
			<RowItem>
				<span>Beta</span>
			</RowItem>
		</RowList>
	{/snippet}
</Story>

<Story name="WithEmptyState">
	{#snippet template()}
		<RowList>
			<RowItem empty>
				<span>No items yet</span>
			</RowItem>
		</RowList>
	{/snippet}
</Story>
