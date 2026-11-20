<!-- SPDX-License-Identifier: BUSL-1.1 -->
<!-- Copyright (c) 2026 Amplitude Solutions Ltd -->

<script lang="ts" module>
	import { defineMeta } from '@storybook/addon-svelte-csf';
	import DvtObject from './DvtObject.svelte';
	import type { DocumentMeta } from '$lib/datasource/types';

	const { Story } = defineMeta({
		title: 'Components/Features/DocumentView/DvtObject',
		component: DvtObject,
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
	name="SimpleObject"
	args={{
		template: {
			type: 'object',
			field: 'address',
			children: [
				{ type: 'field', label: 'Street', value: '$street' },
				{ type: 'field', label: 'City', value: '$city' },
				{ type: 'field', label: 'ZIP', value: '$zip' }
			]
		},
		document: doc({
			address: { street: '456 Oak Ave', city: 'San Francisco', zip: '94102' }
		})
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtObject template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="ObjectWithLabels"
	args={{
		template: {
			type: 'object',
			field: 'contact',
			children: [
				{ type: 'label', value: 'Contact: $name' },
				{ type: 'field', label: 'Email', value: '$email' }
			]
		},
		document: doc({
			contact: { name: 'Bob Smith', email: 'bob@example.com' }
		})
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtObject template={args.template} document={args.document} />
		</div>
	{/snippet}
</Story>

<Story
	name="MissingField"
	args={{
		template: {
			type: 'object',
			field: 'nonexistent',
			children: [{ type: 'label', value: 'Will not render' }]
		},
		document: doc({ name: 'Alice' })
	}}
>
	{#snippet template(args)}
		<div class="dvt-story-frame">
			<DvtObject template={args.template} document={args.document} />
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
