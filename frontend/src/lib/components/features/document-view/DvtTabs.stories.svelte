<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import { expect, within } from 'storybook/test';
	import DvtTabs from './DvtTabs.svelte';
	import type { DocumentMeta } from '$lib/datasource/types';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtTabs',
		component: DvtTabs,
		tags: ['autodocs'],
		argTypes: {
			template: { control: 'object' },
			document: { control: 'object' }
		}
	});

	function doc(data: Record<string, unknown>) {
		return {
			data,
			meta: {
				id: 'test.1',
				mid: 'test.1',
				domain: 'test',
				doc_type: 'Test',
				version: 1,
				schema_version: 1,
				created_at: '2025-01-01T00:00:00Z',
				updated_at: '2025-01-01T00:00:00Z'
			} satisfies DocumentMeta
		};
	}
</script>

<Story
	name="TwoTabs"
	play={async ({ canvasElement }) => {
		const canvas = within(canvasElement);
		await expect(canvas.getByText('Identity')).toBeVisible();
		await expect(canvas.getByText('Address')).toBeVisible();
	}}
	args={{
		template: {
			type: 'tabs',
			tabs: [
				{
					type: 'tab',
					label: 'Identity',
					children: [
						{ type: 'label', value: '$name' },
						{ type: 'label', value: '$email' }
					]
				},
				{
					type: 'tab',
					label: 'Address',
					children: [{ type: 'label', value: '$address.city' }]
				}
			]
		},
		document: doc({
			name: 'Alice Johnson',
			email: 'alice@example.com',
			address: { city: 'Paris' }
		})
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtTabs template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="ThreeTabs"
	args={{
		template: {
			type: 'tabs',
			tabs: [
				{
					type: 'tab',
					label: 'Details',
					children: [{ type: 'label', value: 'Details tab content' }]
				},
				{
					type: 'tab',
					label: 'Activity',
					children: [{ type: 'label', value: '$status' }]
				},
				{
					type: 'tab',
					label: 'Relations',
					children: [{ type: 'label', value: '$related_to' }]
				}
			]
		},
		document: doc({ status: 'Active', related_to: 'Invoice #456' })
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtTabs template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="EmptyTabs"
	args={{
		template: {
			type: 'tabs',
			tabs: []
		},
		document: doc({})
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtTabs template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<style>
	.dvt-story-frame {
		display: block;
		width: 100%;
		max-width: 720px;
		margin: 0 auto;
		padding: 24px;
		background: var(--surface);
		border: 1px solid var(--border);
		border-radius: var(--r-lg);
		box-shadow: var(--sh-1);
		min-height: 120px;
	}
</style>
