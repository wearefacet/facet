<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import DvtGrid from './DvtGrid.svelte';
	import type { DocumentMeta } from '$lib/datasource/types';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtGrid',
		component: DvtGrid,
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
	name="TwoColumnEqual"
	args={{
		template: {
			type: 'grid',
			layout: '1 1',
			children: [
				{
					type: 'col',
					children: [
						{ type: 'title', value: 'Left Column', level: 3 },
						{ type: 'field', label: 'Name', value: '$name' },
						{ type: 'field', label: 'Email', value: '$email' }
					]
				},
				{
					type: 'col',
					children: [
						{ type: 'title', value: 'Right Column', level: 3 },
						{ type: 'field', label: 'Role', value: '$role' },
						{ type: 'field', label: 'Status', value: '$status' }
					]
				}
			]
		},
		document: doc({
			name: 'Alice Johnson',
			email: 'alice@example.com',
			role: 'Engineer',
			status: 'Active'
		})
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtGrid template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="ThreeColumnGrid"
	args={{
		template: {
			type: 'grid',
			layout: '1 1 1',
			children: [
				{ type: 'col', children: [{ type: 'label', value: 'Column A' }] },
				{ type: 'col', children: [{ type: 'label', value: 'Column B' }] },
				{ type: 'col', children: [{ type: 'label', value: 'Column C' }] }
			]
		},
		document: doc({})
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtGrid template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="AsymmetricLayout"
	args={{
		template: {
			type: 'grid',
			layout: '1 3',
			children: [
				{
					type: 'col',
					children: [
						{
							type: 'image',
							src: 'https://api.dicebear.com/9.x/notionists/svg?seed=Avatar',
							variant: 'avatar',
							alt: 'Avatar'
						}
					]
				},
				{
					type: 'col',
					children: [
						{ type: 'title', value: '$first_name $last_name', level: 1 },
						{ type: 'capsule', value: '$employee_id' },
						{ type: 'hr' },
						{ type: 'field', label: 'Department', value: '$department' }
					]
				}
			]
		},
		document: doc({
			first_name: 'Jane',
			last_name: 'Doe',
			employee_id: 'EMP-0042',
			department: 'Engineering'
		})
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtGrid template={args.template} document={args.document} />
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
